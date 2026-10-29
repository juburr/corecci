#!/bin/bash
#
# Runs src/scripts/install_deps.sh offline with a PATH that holds only
# stand-ins: id, and the package managers it may pick, which log how they were
# run and "install" ssh and git by writing stand-ins for them.
#
# Run from a checkout:
#   bash tests/install_deps_test.sh
# Put an older bash first on the PATH to run the script with it.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/src/scripts/install_deps.sh"
BASH_BIN=$(command -v bash)

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# A package manager stand-in: logs "NAME ARGS" and DEBIAN_FRONTEND, then
# writes ssh and git stand-ins into INSTALLED for the packages it was asked
# for, unless STUB_INSTALL_NOTHING is set. STUB_FAIL makes it fail instead.
# The PATH holds no coreutils, so STUB_CHMOD names chmod.
cat > "${WORK}/manager" << 'EOF'
#!/bin/bash
name=${0##*/}
echo "${name} $* (DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-})" >> "${STUB_LOG}"
if [[ -n "${STUB_FAIL:-}" ]]; then
    echo "${name}: failed" >&2
    exit 1
fi
if [[ -n "${STUB_INSTALL_NOTHING:-}" ]]; then
    exit 0
fi
for arg in "$@"; do
    case "${arg}" in
        openssh-client | openssh-clients) tool=ssh ;;
        git) tool=git ;;
        *) continue ;;
    esac
    printf '#!/bin/bash\necho "%s stand-in" >&2\n' "${tool}" > "${STUB_INSTALLED}/${tool}"
    "${STUB_CHMOD}" +x "${STUB_INSTALLED}/${tool}"
done
EOF
chmod +x "${WORK}/manager"

CASE=0
# run_install UID [TOOL...] -- [MANAGER...]: runs install_deps.sh as UID with
# the TOOLs already installed and the MANAGERs on the PATH. Sets RC, OUTPUT and
# LOG (the package managers' log). STUB_FAIL and STUB_INSTALL_NOTHING pass
# through when set.
run_install() {
    local uid=$1
    shift
    CASE=$((CASE + 1))
    local dir="${WORK}/case-${CASE}"
    mkdir -p "${dir}/bin" "${dir}/installed"
    printf '#!%s\necho %s\n' "${BASH_BIN}" "${uid}" > "${dir}/bin/id"
    chmod +x "${dir}/bin/id"
    while [[ $# -gt 0 && "$1" != -- ]]; do
        printf '#!/bin/bash\necho "%s stand-in" >&2\n' "$1" > "${dir}/installed/$1"
        chmod +x "${dir}/installed/$1"
        shift
    done
    shift
    while [[ $# -gt 0 ]]; do
        ln -s "${WORK}/manager" "${dir}/bin/$1"
        shift
    done
    : > "${dir}/log"
    set +e
    OUTPUT=$(env -i PATH="${dir}/bin:${dir}/installed" \
        STUB_LOG="${dir}/log" STUB_INSTALLED="${dir}/installed" STUB_CHMOD="$(command -v chmod)" \
        STUB_FAIL="${STUB_FAIL:-}" STUB_INSTALL_NOTHING="${STUB_INSTALL_NOTHING:-}" \
        "${BASH_BIN}" "${SCRIPT}" 2>&1)
    RC=$?
    set -e
    LOG=$(cat "${dir}/log")
}

PASSES=0
FAILURES=0
check() {
    local name=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
        printf 'ok: %s\n' "${name}"
    else
        FAILURES=$((FAILURES + 1))
        printf 'FAIL: %s\n' "${name}"
        printf '%s\n' "${OUTPUT}" | sed 's/^/    | /'
        printf '%s\n' "${LOG}" | sed 's/^/    log | /'
    fi
}
rc_is() { [[ "${RC}" == "$1" ]]; }
rc_is_not() { [[ "${RC}" != "$1" ]]; }
equals() { [[ "$1" == "$2" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }

run_install 0 ssh git -- apt-get dnf
check "nothing is installed when ssh and git are there" rc_is 0
check "no package manager runs when ssh and git are there" equals "${LOG}" ""
check "the versions are logged" output_has "ssh stand-in"

run_install 0 -- apt-get
check "apt-get installs ssh and git" rc_is 0
check "apt-get updates, then installs openssh-client and git noninteractively" equals "${LOG}" \
    "apt-get update (DEBIAN_FRONTEND=)
apt-get install -y --no-install-recommends openssh-client git (DEBIAN_FRONTEND=noninteractive)"

run_install 0 -- apk
check "apk installs openssh-client and git" equals "${LOG}" "apk add --no-cache openssh-client git (DEBIAN_FRONTEND=)"

run_install 0 -- dnf yum
check "dnf comes before yum" equals "${LOG}" "dnf install -y openssh-clients git (DEBIAN_FRONTEND=)"

run_install 0 -- microdnf
check "microdnf installs on UBI minimal" equals "${LOG}" "microdnf install -y openssh-clients git (DEBIAN_FRONTEND=)"

run_install 0 -- yum
check "yum installs where it is the only package manager" equals "${LOG}" "yum install -y openssh-clients git (DEBIAN_FRONTEND=)"

run_install 0 ssh -- dnf
check "only a missing git is installed" equals "${LOG}" "dnf install -y git (DEBIAN_FRONTEND=)"

run_install 0 git -- apt-get
check "only a missing ssh is installed" equals "$(tail -n 1 <<< "${LOG}")" \
    "apt-get install -y --no-install-recommends openssh-client (DEBIAN_FRONTEND=noninteractive)"

run_install 0 --
check "no package manager fails" rc_is 1
check "no package manager says which tools are missing" \
    output_has "ERROR: ssh git must be installed, and no supported package manager (apt-get, apk, dnf, microdnf or yum) was found."

run_install 1000 -- dnf
check "a non-root user is warned" output_has "WARN: Not running as root, so dnf may not be able to install packages."
check "a non-root user still tries" rc_is 0

STUB_INSTALL_NOTHING=1
run_install 0 -- dnf
unset STUB_INSTALL_NOTHING
check "a tool still missing after the install fails" rc_is 1
check "a tool still missing after the install says so" output_has "ERROR: dnf finished, but ssh is still not on the PATH."

STUB_FAIL=1
run_install 0 -- yum
unset STUB_FAIL
check "a failing package manager fails the step" rc_is_not 0
check "a failing package manager's error is shown" output_has "yum: failed"

echo
if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} of $((PASSES + FAILURES)) checks failed."
    exit 1
fi
echo "All ${PASSES} checks passed."
