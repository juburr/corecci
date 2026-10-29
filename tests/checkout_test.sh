#!/bin/bash
#
# Runs src/scripts/checkout.sh offline against local repositories, with the
# real git and stand-ins for ssh, ssh-keygen and the CircleCI CLI:
#
#   - The ssh stand-in checks the host key the way StrictHostKeyChecking=yes
#     does, against a server key the test chooses, and serves
#     git-upload-pack from bare repositories under the test's directory. With
#     StrictHostKeyChecking=accept-new it records the server key instead.
#   - ssh-keygen prints a key file's fingerprint from a "fingerprint:" line in
#     it, and finds hosts in known_hosts files.
#   - circleci reads env subst's value on stdin, fails on any argument after
#     it, and expands $ORB_TEST_VAR.
#
# Run from a checkout:
#   bash tests/checkout_test.sh
# Put an older bash first on the PATH to run the script with it.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/src/scripts/checkout.sh"

# git settings from the environment (GIT_CONFIG_COUNT and the like) would
# reach the fixtures and the script.
while IFS= read -r name; do
    unset "${name}"
done < <(compgen -e | grep '^GIT_' || true)
export GIT_CONFIG_NOSYSTEM=1

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
export HOME="${WORK}/fixture-home"
mkdir -p "${HOME}"

GITHUB_ECDSA='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg='
EXAMPLE_KEY='ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBEXAMPLEKEY'
OTHER_KEY='ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBOTHERKEY'

# --- Fixture repositories ---------------------------------------------------

REMOTE="${WORK}/remote"
mkdir -p "${REMOTE}/juburr"
fixture_git() {
    git -c user.name=Fixture -c user.email=fixture@example.com -c init.defaultBranch=main "$@"
}

fixture_git init -q "${WORK}/sub"
echo "submodule one" > "${WORK}/sub/sub.txt"
fixture_git -C "${WORK}/sub" add sub.txt
fixture_git -C "${WORK}/sub" commit -q -m "sub one"
SUB1=$(git -C "${WORK}/sub" rev-parse HEAD)
echo "submodule two" > "${WORK}/sub/sub.txt"
fixture_git -C "${WORK}/sub" commit -q -am "sub two"

fixture_git init -q "${WORK}/main"
echo "one" > "${WORK}/main/file.txt"
fixture_git -C "${WORK}/main" add file.txt
fixture_git -C "${WORK}/main" commit -q -m "one"
printf '[submodule "sub"]\n\tpath = sub\n\turl = git@github.com:juburr/sub.git\n' > "${WORK}/main/.gitmodules"
echo "two" > "${WORK}/main/file.txt"
fixture_git -C "${WORK}/main" add .gitmodules file.txt
fixture_git -C "${WORK}/main" update-index --add --cacheinfo "160000,${SUB1},sub"
fixture_git -C "${WORK}/main" commit -q -m "two"
SHA2=$(git -C "${WORK}/main" rev-parse HEAD)
fixture_git -C "${WORK}/main" tag v1.0.0
echo "three" > "${WORK}/main/file.txt"
fixture_git -C "${WORK}/main" commit -q -am "three"
SHA3=$(git -C "${WORK}/main" rev-parse HEAD)

for repo in sub main; do
    name=${repo/main/fixture}
    git clone -q --bare "${WORK}/${repo}" "${REMOTE}/juburr/${name}.git"
    # GitHub serves any reachable commit, which shallow fetches ask for.
    git -C "${REMOTE}/juburr/${name}.git" config uploadpack.allowReachableSHA1InWant true
done

# --- Stand-ins --------------------------------------------------------------

STUBS="${WORK}/stubs"
CLI_STUB="${WORK}/cli-stub"
mkdir -p "${STUBS}" "${CLI_STUB}"

cat > "${STUBS}/ssh" << 'EOF'
#!/bin/bash
# ssh stand-in: logs its arguments, checks or records the host key, and
# serves git-upload-pack from STUB_REMOTE_ROOT.
{ printf 'CALL'; printf ' %s' "$@"; printf '\n'; } >> "${STUB_SSH_LOG}"
if [[ "${1:-}" == -V ]]; then
    echo "OpenSSH_stub" >&2
    exit 0
fi
args=("$@")
known="" accept=false port=22 host="" i=0
while [[ ${i} -lt ${#args[@]} ]]; do
    case "${args[i]}" in
        -o)
            case "${args[i + 1]}" in
                UserKnownHostsFile=*) known=${args[i + 1]#*=} ;;
                StrictHostKeyChecking=accept-new) accept=true ;;
            esac
            i=$((i + 2))
            ;;
        -p) port=${args[i + 1]}; i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) host=${args[i]#*@}; i=$((i + 1)); break ;;
    esac
done
remote_command="${args[*]:i}"
name=${host}
if [[ "${port}" != 22 ]]; then
    name="[${host}]:${port}"
fi
if [[ "${accept}" == true ]]; then
    if [[ -n "${STUB_SCAN_FAIL:-}" ]]; then
        echo "ssh: connect to host ${host} port ${port}: Connection refused" >&2
        exit 255
    fi
    printf '%s %s\n' "${name}" "${STUB_SERVER_KEY}" >> "${known}"
    echo "Warning: Permanently added '${name}' to the list of known hosts." >&2
    echo "git@${host}: Permission denied (publickey)." >&2
    exit 255
fi
if ! awk -v n="${name}" -v k="${STUB_SERVER_KEY}" '$1 == n && ($2 " " $3) == k { found = 1 } END { exit !found }' "${known}" 2> /dev/null; then
    echo "Host key verification failed." >&2
    exit 255
fi
case "${remote_command}" in
    "git-upload-pack '"*"'")
        path=${remote_command#git-upload-pack \'}
        path=${path%\'}
        cd "${STUB_REMOTE_ROOT}" || exit 1
        exec git upload-pack "${path#/}"
        ;;
esac
echo "ssh stand-in: unexpected command '${remote_command}'" >&2
exit 1
EOF

cat > "${STUBS}/ssh-keygen" << 'EOF'
#!/bin/bash
# ssh-keygen stand-in: -l -E sha256 -f FILE prints the fingerprint on FILE's
# "fingerprint:" line; -F HOST -f FILE finds HOST in a known_hosts FILE.
if [[ "$1" == -l ]]; then
    fingerprint=$(awk '/^fingerprint: / { print $2 }' "${5}")
    if [[ -z "${fingerprint}" ]]; then
        echo "${5} is not a key file." >&2
        exit 1
    fi
    echo "384 ${fingerprint} stub (ECDSA)"
    exit 0
fi
if [[ "$1" == -F ]]; then
    awk -v n="$2" '$1 == n { found = 1; print } END { exit !found }' "$4"
    exit
fi
echo "ssh-keygen stand-in: unexpected arguments $*" >&2
exit 1
EOF

cat > "${CLI_STUB}/circleci" << 'EOF'
#!/bin/bash
# circleci stand-in for env subst: the value comes on stdin, never as an
# argument, and $ORB_TEST_VAR is expanded.
if [[ $# -ne 2 || "$1" != env || "$2" != subst ]]; then
    echo "circleci stand-in: unexpected arguments: $*" >&2
    exit 2
fi
value=$(cat; printf x)
value=${value%x}
value=${value//'${ORB_TEST_VAR}'/${ORB_TEST_VAR:-}}
value=${value//'$ORB_TEST_VAR'/${ORB_TEST_VAR:-}}
printf '%s' "${value}"
EOF
chmod +x "${STUBS}"/* "${CLI_STUB}/circleci"

# The system PATH without directories that hold a real circleci, so the
# script runs without the CLI unless a test adds the stand-in.
BASE_PATH=""
IFS=: read -r -a path_dirs <<< "${PATH}"
for dir in "${path_dirs[@]}"; do
    if [[ -n "${dir}" && ! -x "${dir}/circleci" ]]; then
        BASE_PATH="${BASE_PATH:+${BASE_PATH}:}${dir}"
    fi
done
if ! PATH=${BASE_PATH} command -v git > /dev/null; then
    echo "ERROR: git is not on the PATH without the CircleCI CLI's directory." >&2
    exit 1
fi

# --- Running the script -----------------------------------------------------

CASE=0
WITH_CLI=false
PREPARE=""
SERVER_KEY=${GITHUB_ECDSA}

# run_checkout [VAR=value ...]: runs checkout.sh in a new empty directory with
# a new HOME, the command's defaults and a github.com repository at SHA2,
# overridden by the given assignments. Sets RC, OUTPUT, CO (the checkout),
# HOME_DIR and BASH_ENV_FILE. PREPARE names a function run with HOME_DIR
# first. (Bash 4.0 takes an empty "$@" for an unbound variable, so the
# assignments are copied only when there are some.)
run_checkout() {
    local -a vars=()
    if [[ $# -gt 0 ]]; then
        vars=("$@")
    fi
    local path=${STUBS}:${BASE_PATH}
    if [[ "${WITH_CLI}" == true ]]; then
        path=${CLI_STUB}:${path}
    fi
    CASE=$((CASE + 1))
    HOME_DIR="${WORK}/home ${CASE}"
    CO="${WORK}/checkout-${CASE}"
    BASH_ENV_FILE="${WORK}/bash-env-${CASE}"
    mkdir -p "${HOME_DIR}" "${CO}"
    : > "${BASH_ENV_FILE}"
    : > "${WORK}/ssh.log"
    if [[ -n "${PREPARE}" ]]; then
        "${PREPARE}" "${HOME_DIR}"
    fi
    set +e
    OUTPUT=$(cd "${CO}" && env -i \
        PATH="${path}" \
        HOME="${HOME_DIR}" \
        BASH_ENV="${BASH_ENV_FILE}" \
        GIT_CONFIG_NOSYSTEM=1 \
        STUB_SSH_LOG="${WORK}/ssh.log" \
        STUB_REMOTE_ROOT="${REMOTE}" \
        STUB_SERVER_KEY="${SERVER_KEY}" \
        CIRCLE_REPOSITORY_URL=git@github.com:juburr/fixture.git \
        CIRCLE_SHA1="${SHA2}" \
        CIRCLE_BRANCH=main \
        PARAM_CONFIGURE_GIT_SSH=true \
        PARAM_DEPTH=full \
        PARAM_FINGERPRINT="" \
        PARAM_SSH_ACCEPT_NEW_HOST_KEY=false \
        PARAM_SSH_CIPHERS=aes256-gcm@openssh.com \
        PARAM_SSH_FINGERPRINT_HASH=sha384 \
        PARAM_SSH_HOST_KEY_ALGORITHMS=ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512 \
        PARAM_SSH_KEX_ALGORITHMS=ecdh-sha2-nistp384 \
        PARAM_SSH_KNOWN_HOSTS="" \
        PARAM_SUBMODULES=none \
        ${vars[@]+"${vars[@]}"} \
        bash "${SCRIPT}" 2>&1)
    RC=$?
    set -e
}

PASSES=0
FAILURES=0
pass() {
    PASSES=$((PASSES + 1))
    printf 'ok: %s\n' "$1"
}
fail() {
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n' "$1"
    printf '%s\n' "${OUTPUT}" | sed 's/^/    | /'
}
# check NAME COMMAND...: passes if COMMAND succeeds.
check() {
    local name=$1
    shift
    if "$@"; then
        pass "${name}"
    else
        fail "${name}"
    fi
}
rc_is() { [[ "${RC}" == "$1" ]]; }
output_has() { [[ "${OUTPUT}" == *"$1"* ]]; }
ssh_log_has() { grep -qF -- "$1" "${WORK}/ssh.log"; }
ssh_not_run() { [[ ! -s "${WORK}/ssh.log" ]]; }
ssh_log_lacks() { ! grep -qF -- "$1" "${WORK}/ssh.log"; }
output_lacks() { [[ "${OUTPUT}" != *"$1"* ]]; }
co_git() { git -C "${CO}" "$@"; }
equals() { [[ "$1" == "$2" ]]; }
known_hosts_has() { grep -qxF -- "$1" "${HOME_DIR}/.ssh/known_hosts"; }
known_hosts_lacks_host() { ! grep -q "^$1 " "${HOME_DIR}/.ssh/known_hosts"; }
git_config_global() { HOME=${HOME_DIR} git config --global --get "$1" || true; }

# --- Full, shallow and empty checkouts --------------------------------------

run_checkout
check "a full checkout succeeds" rc_is 0
check "a full checkout is at CIRCLE_SHA1" equals "$(co_git rev-parse HEAD)" "${SHA2}"
check "a full checkout has the history" equals "$(co_git rev-list --count HEAD)" 2
check "a full checkout has every branch" equals "$(co_git rev-parse origin/main)" "${SHA3}"
check "GitHub's published host keys are added for github.com" known_hosts_has "github.com ${GITHUB_ECDSA}"
check "all three of GitHub's published keys are added" equals "$(grep -c '^github.com ' "${HOME_DIR}/.ssh/known_hosts")" 3
check "the .ssh directory is private" equals "$(stat -c %a "${HOME_DIR}/.ssh")" 700
check "ssh checks the host key" ssh_log_has "-o StrictHostKeyChecking=yes"
check "ssh uses the ciphers" ssh_log_has "-o Ciphers=aes256-gcm@openssh.com"
check "ssh uses the key exchange algorithms" ssh_log_has "-o KexAlgorithms=ecdh-sha2-nistp384"
check "ssh uses the host key algorithms" ssh_log_has "-o HostKeyAlgorithms=ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512"
check "ssh uses the fingerprint hash" ssh_log_has "-o FingerprintHash=sha384"
check "ssh uses no key file without a fingerprint" ssh_log_lacks IdentityFile
check "ssh never accepts a new host key by default" ssh_log_lacks accept-new
check "configure_git_ssh fetches https://github.com/ over SSH" \
    equals "$(git_config_global url.ssh://git@github.com/.insteadOf)" "https://github.com/"
check "a missing CircleCI CLI is a warning" output_has "WARN: The CircleCI CLI is not installed"

# GIT_SSH_COMMAND reaches later steps through BASH_ENV, and git runs it with
# sh, so it must read the same in both shells.
# sourced_words: prints the words sh reads in the GIT_SSH_COMMAND that
# BASH_ENV_FILE exports, joined by |, so a word split at a space shows.
sourced_words() {
    # shellcheck disable=SC2016 # expanded by the inner shells
    env -i bash -c '. "$1"; sh -c "printf \"%s\\n\" $GIT_SSH_COMMAND"' _ "${BASH_ENV_FILE}" | paste -sd'|' -
}
# expected_words [WORD...]: prints the words of GIT_SSH_COMMAND for the
# defaults and HOME_DIR, then WORDs, joined by |.
expected_words() {
    local words="ssh|-o|KexAlgorithms=ecdh-sha2-nistp384|-o|HostKeyAlgorithms=ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512|-o|Ciphers=aes256-gcm@openssh.com|-o|StrictHostKeyChecking=yes|-o|UserKnownHostsFile=${HOME_DIR}/.ssh/known_hosts|-o|FingerprintHash=sha384|-o|ForwardAgent=no|-o|ForwardX11=no"
    local word
    # Bash 4.0 takes an empty "$@" for an unbound variable.
    if [[ $# -gt 0 ]]; then
        for word in "$@"; do
            words+="|${word}"
        done
    fi
    printf '%s\n' "${words}"
}
check "BASH_ENV exports GIT_SSH_COMMAND, read the same by sh" equals "$(sourced_words)" "$(expected_words)"
check "BASH_ENV holds only the GIT_SSH_COMMAND export" equals "$(grep -c . "${BASH_ENV_FILE}")" 1
: > "${WORK}/ssh.log"
# shellcheck disable=SC2016 # expanded by the inner shell
FETCH_OUTPUT=$(env -i PATH="${STUBS}:${BASE_PATH}" HOME="${HOME_DIR}" GIT_CONFIG_NOSYSTEM=1 \
    STUB_SSH_LOG="${WORK}/ssh.log" STUB_REMOTE_ROOT="${REMOTE}" STUB_SERVER_KEY="${SERVER_KEY}" \
    bash -c '. "$1" && git -C "$2" fetch -q origin' _ "${BASH_ENV_FILE}" "${CO}" 2>&1) && FETCH_RC=0 || FETCH_RC=$?
OUTPUT=${FETCH_OUTPUT}
check "a later step fetches with the exported GIT_SSH_COMMAND" equals "${FETCH_RC}" 0
check "the later fetch checks the host key" ssh_log_has "-o StrictHostKeyChecking=yes"

run_checkout PARAM_DEPTH=shallow
check "a shallow checkout succeeds" rc_is 0
check "a shallow checkout is at CIRCLE_SHA1" equals "$(co_git rev-parse HEAD)" "${SHA2}"
check "a shallow checkout has one commit" equals "$(co_git rev-list --count HEAD)" 1

run_checkout PARAM_DEPTH=empty
check "an empty checkout succeeds" rc_is 0
check "an empty checkout leaves only .git in the working directory" equals "$(ls -A "${CO}")" ".git"
check "an empty checkout has the history" equals "$(co_git rev-list --count origin/main)" 3

# --- Submodules -------------------------------------------------------------

run_checkout PARAM_SUBMODULES=recursive-shallow
check "recursive-shallow submodules succeed" rc_is 0
check "the submodule is at the recorded commit" equals "$(git -C "${CO}/sub" rev-parse HEAD)" "${SUB1}"
check "the shallow submodule has one commit" equals "$(git -C "${CO}/sub" rev-list --count HEAD)" 1

run_checkout PARAM_SUBMODULES=top-level PARAM_DEPTH=shallow
check "top-level submodules succeed" rc_is 0
check "the top-level submodule is checked out" equals "$(cat "${CO}/sub/sub.txt" 2> /dev/null)" "submodule one"

run_checkout PARAM_DEPTH=empty PARAM_SUBMODULES=recursive
check "submodules with an empty checkout fail" rc_is 1
check "submodules with an empty checkout say why" output_has "ERROR: Submodules cannot be checked out when depth is empty."
check "submodules with an empty checkout fail before ssh runs" ssh_not_run

# --- Parameter checks -------------------------------------------------------

run_checkout PARAM_DEPTH=re
check "a partial depth fails" rc_is 1
check "a partial depth names the parameter" output_has "ERROR: depth must be full, shallow or empty, not 're'."
check "a bad depth fails before ssh runs" ssh_not_run

run_checkout PARAM_SUBMODULES=recursive-shallow-x
check "a bad submodules value fails" output_has "ERROR: submodules must be none, recursive, recursive-shallow, top-level or top-level-shallow"

run_checkout PARAM_CONFIGURE_GIT_SSH=yes
check "a bad boolean fails" rc_is 1
check "a bad boolean names the parameter" output_has "ERROR: configure_git_ssh must be true or false, not 'yes'."

run_checkout PARAM_SSH_ACCEPT_NEW_HOST_KEY=maybe
check "a bad ssh_accept_new_host_key fails" output_has "ERROR: ssh_accept_new_host_key must be true or false"

run_checkout "PARAM_SSH_CIPHERS=aes256-gcm@openssh.com -oProxyCommand=touch"
check "an ssh value with a space fails" rc_is 1
check "an ssh value with a space names the parameter" output_has "ERROR: ssh_ciphers may only hold algorithm names"
check "an ssh value with a space never reaches ssh" ssh_not_run

run_checkout 'PARAM_SSH_KEX_ALGORITHMS=ecdh-sha2-nistp384;id'
check "an ssh value with a shell operator fails" output_has "ERROR: ssh_kex_algorithms may only hold algorithm names"

run_checkout LC_ALL=C.UTF-8 'PARAM_SSH_CIPHERS=aes256-gcm@openssh.cöm'
check "an ssh value with a non-ASCII letter fails in a UTF-8 locale" output_has "ERROR: ssh_ciphers may only hold algorithm names"

run_checkout PARAM_CONFIGURE_GIT_SSH=0
check "configure_git_ssh takes 0" rc_is 0
check "configure_git_ssh 0 leaves git's config alone" equals "$(git_config_global url.ssh://git@github.com/.insteadOf)" ""

run_checkout PARAM_SSH_ACCEPT_NEW_HOST_KEY=1
check "ssh_accept_new_host_key takes 1" rc_is 0
check "github.com uses the published keys even with ssh_accept_new_host_key" ssh_log_lacks accept-new

# --- Host keys for other servers --------------------------------------------

SERVER_KEY=${EXAMPLE_KEY}
EXAMPLE_URL=CIRCLE_REPOSITORY_URL=git@git.example.com:juburr/fixture.git

run_checkout "${EXAMPLE_URL}"
check "an unknown host fails" rc_is 1
check "an unknown host says how to supply its keys" output_has "ERROR: No host key is known for git.example.com"
check "an unknown host names ssh_known_hosts" output_has "set ssh_accept_new_host_key to true"
check "an unknown host fails before ssh runs" ssh_not_run
check "an unknown host checks nothing out" equals "$(ls -A "${CO}")" ""

run_checkout "${EXAMPLE_URL}" "PARAM_SSH_KNOWN_HOSTS=git.example.com ${EXAMPLE_KEY}"
check "ssh_known_hosts lets an unknown host check out" rc_is 0
check "ssh_known_hosts lines are added" known_hosts_has "git.example.com ${EXAMPLE_KEY}"
check "ssh_known_hosts replaces GitHub's keys" known_hosts_lacks_host github.com

run_checkout "${EXAMPLE_URL}" "PARAM_SSH_KNOWN_HOSTS=git.example.com ${OTHER_KEY}"
check "a server whose key isn't in ssh_known_hosts fails" rc_is 1
check "a host key mismatch fails the clone" output_has "Host key verification failed."
check "a host key mismatch is reported" output_has "ERROR: git clone failed."

two_hosts() {
    mkdir -p "$1/.ssh"
    printf 'other.example.com %s\ngit.example.com %s\n' "${OTHER_KEY}" "${EXAMPLE_KEY}" > "$1/.ssh/known_hosts"
}
PREPARE=two_hosts
run_checkout "${EXAMPLE_URL}"
PREPARE=""
check "a host already in known_hosts checks out" rc_is 0
check "a host already in known_hosts is used as it is" output_has "already in the image's known_hosts"
check "a host already in known_hosts is not scanned" ssh_log_lacks accept-new

run_checkout "${EXAMPLE_URL}" PARAM_SSH_ACCEPT_NEW_HOST_KEY=true
check "ssh_accept_new_host_key checks out" rc_is 0
check "ssh_accept_new_host_key warns" output_has "WARN: Trusting the host key git.example.com presents now"
check "ssh_accept_new_host_key records the key" known_hosts_has "git.example.com ${EXAMPLE_KEY}"
check "the scan uses no key" ssh_log_has "-o PubkeyAuthentication=no"
check "the scan accepts only a new key" ssh_log_has "-o StrictHostKeyChecking=accept-new"
check "the scan uses the key exchange algorithms" ssh_log_has "-o KexAlgorithms=ecdh-sha2-nistp384 -o HostKeyAlgorithms="
check "the clone after the scan checks the host key" ssh_log_has "-o StrictHostKeyChecking=yes"

run_checkout "${EXAMPLE_URL}" PARAM_SSH_ACCEPT_NEW_HOST_KEY=true STUB_SCAN_FAIL=1
check "a scan that gets no key fails" rc_is 1
check "a scan that gets no key shows ssh's output" output_has "Connection refused"

PORT_URL=CIRCLE_REPOSITORY_URL=ssh://git@git.example.com:2222/juburr/fixture.git
run_checkout "${PORT_URL}" PARAM_SSH_ACCEPT_NEW_HOST_KEY=true
check "an ssh:// URL with a port checks out" rc_is 0
check "a host on another port is recorded as [host]:port" known_hosts_has "[git.example.com]:2222 ${EXAMPLE_KEY}"
check "the scan uses the port" ssh_log_has "-p 2222 git@git.example.com exit"
check "configure_git_ssh keeps the port" \
    equals "$(git_config_global url.ssh://git@git.example.com:2222/.insteadOf)" "https://git.example.com/"

run_checkout "${PORT_URL}" "PARAM_SSH_KNOWN_HOSTS=git.example.com ${EXAMPLE_KEY}"
check "a key for port 22 doesn't cover another port" rc_is 1
check "ssh_known_hosts without the host is a warning" output_has "WARN: No line in ssh_known_hosts names [git.example.com]:2222"

run_checkout "${PORT_URL}" "PARAM_SSH_KNOWN_HOSTS=[git.example.com]:2222 ${EXAMPLE_KEY}"
check "ssh_known_hosts with [host]:port checks out" rc_is 0
check "ssh_known_hosts with the host isn't a warning" output_lacks "WARN: No line in ssh_known_hosts"

SERVER_KEY=${GITHUB_ECDSA}
run_checkout CIRCLE_REPOSITORY_URL=https://github.com/juburr/fixture
check "an https URL checks out over SSH" rc_is 0
check "an https URL becomes git@host:path" output_has "Computed clone URL: git@github.com:juburr/fixture"

run_checkout CIRCLE_REPOSITORY_URL=github.com/juburr/fixture
check "a URL in no known form fails" rc_is 1
check "a URL in no known form says so" output_has "ERROR: CIRCLE_REPOSITORY_URL is 'github.com/juburr/fixture', not a repository URL"

run_checkout CIRCLE_REPOSITORY_URL=
check "a missing CIRCLE_REPOSITORY_URL fails" output_has "ERROR: CIRCLE_REPOSITORY_URL is '', not a repository URL"

run_checkout 'CIRCLE_REPOSITORY_URL=git@git.example.com;id:juburr/fixture.git'
check "a host that isn't a host name fails" output_has "ERROR: Can't read the SSH user, host and port"

# --- Fingerprints -----------------------------------------------------------

MD5=e8:35:14:20:8c:57:a3:68:b3:6e:cc:3d:b8:72:bf:88
md5_key() {
    mkdir -p "$1/.ssh"
    echo "private key" > "$1/.ssh/id_rsa_e83514208c57a368b36ecc3db872bf88"
}
PREPARE=md5_key
run_checkout "PARAM_FINGERPRINT=${MD5}"
PREPARE=""
check "an MD5 fingerprint checks out" rc_is 0
check "an MD5 fingerprint uses its key file only" \
    ssh_log_has "-o IdentitiesOnly=yes -o IdentityAgent=none -o IdentityFile=${HOME_DIR}/.ssh/id_rsa_e83514208c57a368b36ecc3db872bf88"
check "a key file path with a space survives BASH_ENV and sh" \
    equals "$(sourced_words)" "$(expected_words -o IdentitiesOnly=yes -o IdentityAgent=none -o "IdentityFile=${HOME_DIR}/.ssh/id_rsa_e83514208c57a368b36ecc3db872bf88")"

PREPARE=md5_key
run_checkout "PARAM_FINGERPRINT=MD5:${MD5^^}"
PREPARE=""
check "an uppercase MD5: fingerprint finds CircleCI's lowercase file" ssh_log_has "-o IdentityFile=${HOME_DIR}/.ssh/id_rsa_e83514208c57a368b36ecc3db872bf88"

run_checkout "PARAM_FINGERPRINT=${MD5}"
check "an MD5 fingerprint without its key file fails" rc_is 1
check "an MD5 fingerprint without its key file names the file" output_has "ERROR: ${HOME_DIR}/.ssh/id_rsa_e83514208c57a368b36ecc3db872bf88 does not exist."

sha256_keys() {
    mkdir -p "$1/.ssh"
    printf 'fingerprint: SHA256:aaaa\n' > "$1/.ssh/id_rsa_aaaa"
    printf 'fingerprint: SHA256:bbbb\n' > "$1/.ssh/id_rsa_bbbb"
    printf 'fingerprint: SHA256:bbbb\n' > "$1/.ssh/id_rsa_bbbb.pub"
    echo "no fingerprint" > "$1/.ssh/id_rsa_cccc"
}
PREPARE=sha256_keys
run_checkout PARAM_FINGERPRINT=SHA256:bbbb
check "a SHA256 fingerprint checks out" rc_is 0
check "a SHA256 fingerprint uses the matching key file" ssh_log_has "-o IdentityFile=${HOME_DIR}/.ssh/id_rsa_bbbb -o"
run_checkout PARAM_FINGERPRINT=SHA256:dddd
PREPARE=""
check "a SHA256 fingerprint no key has fails" rc_is 1
check "a SHA256 fingerprint no key has says so" output_has "ERROR: No key in ${HOME_DIR}/.ssh has the fingerprint SHA256:dddd."

run_checkout PARAM_FINGERPRINT=not-a-fingerprint
check "a malformed fingerprint fails" output_has "ERROR: fingerprint must be a SHA256:... or MD5 (aa:bb:...) fingerprint"

# --- The commit to check out ------------------------------------------------

run_checkout CIRCLE_SHA1= CIRCLE_BRANCH= CIRCLE_TAG=v1.0.0
check "CIRCLE_TAG is checked out without CIRCLE_SHA1" equals "$(co_git rev-parse HEAD)" "${SHA2}"

run_checkout CIRCLE_SHA1= CIRCLE_BRANCH=main
check "CIRCLE_BRANCH is checked out without CIRCLE_SHA1 or CIRCLE_TAG" equals "$(co_git rev-parse HEAD)" "${SHA3}"

run_checkout CIRCLE_SHA1= CIRCLE_BRANCH=
check "no commit to check out fails" output_has "ERROR: CIRCLE_SHA1, CIRCLE_TAG and CIRCLE_BRANCH are all empty"

# --- The CircleCI CLI -------------------------------------------------------

SERVER_KEY=${EXAMPLE_KEY}
WITH_CLI=true
# shellcheck disable=SC2016 # expanded by the circleci stand-in
run_checkout "${EXAMPLE_URL}" "ORB_TEST_VAR=git.example.com ${EXAMPLE_KEY}" 'PARAM_SSH_KNOWN_HOSTS=${ORB_TEST_VAR}'
check "parameters go through circleci env subst on stdin" rc_is 0
check "env subst expands variables in ssh_known_hosts" known_hosts_has "git.example.com ${EXAMPLE_KEY}"
check "no warning when the CLI is installed" output_lacks "CircleCI CLI is not installed"
WITH_CLI=false

echo
if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} of $((PASSES + FAILURES)) checks failed."
    exit 1
fi
echo "All ${PASSES} checks passed."
