#!/bin/bash
#
# Checks out the pipeline's commit over SSH, in place of CircleCI's built-in
# checkout step, with the SSH algorithms the parameters name. The server's
# host key must be known before anything connects: GitHub's published keys
# for github.com, the lines in ssh_known_hosts, or, with
# ssh_accept_new_host_key, whatever key the server presents first.

set -euo pipefail

# GitHub's SSH host keys, as GitHub publishes them for known_hosts at
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# (SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU Ed25519,
# SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM ECDSA,
# SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s RSA).
GITHUB_KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

for cmd in git ssh; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        echo "ERROR: ${cmd} is required but not installed. Set install_packages to true to install it." >&2
        exit 1
    fi
done
HAVE_CIRCLECI=false
if command -v circleci > /dev/null 2>&1; then
    HAVE_CIRCLECI=true
else
    echo "WARN: The CircleCI CLI is not installed, so environment variables in parameters are not expanded." >&2
fi

# subst VALUE: prints VALUE with environment variables expanded by the
# CircleCI CLI, which reads it on stdin, or as it is without the CLI.
subst() {
    if [[ "${HAVE_CIRCLECI}" == true ]]; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# c_match VALUE REGEX: [[ VALUE =~ REGEX ]] in the C locale, where [A-Za-z]
# matches ASCII letters only, whatever the job's locale.
c_match() {
    local LC_ALL=C
    [[ "$1" =~ $2 ]]
}

# bool NAME VALUE: prints true or false for a boolean parameter's value.
bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            return 1
            ;;
    esac
}

# ssh_value NAME VALUE: fails unless VALUE can be an ssh option value: a
# word of letters, digits and @ . , + _ -, as the algorithm names are.
# GIT_SSH_COMMAND is run by a shell, so nothing else may reach it.
ssh_value() {
    if ! c_match "$2" '^[A-Za-z0-9@.,+_-]+$'; then
        echo "ERROR: ${1} may only hold algorithm names (letters, digits and @.,+_-), not '${2}'." >&2
        return 1
    fi
}

CONFIGURE_GIT_SSH=$(bool configure_git_ssh "$(subst "${PARAM_CONFIGURE_GIT_SSH}")")
DEPTH=$(subst "${PARAM_DEPTH}")
SSH_ACCEPT_NEW_HOST_KEY=$(bool ssh_accept_new_host_key "$(subst "${PARAM_SSH_ACCEPT_NEW_HOST_KEY}")")
SSH_CIPHERS=$(subst "${PARAM_SSH_CIPHERS}")
SSH_FINGERPRINT_HASH=$(subst "${PARAM_SSH_FINGERPRINT_HASH}")
SSH_HOST_KEY_ALGORITHMS=$(subst "${PARAM_SSH_HOST_KEY_ALGORITHMS}")
SSH_KEX_ALGORITHMS=$(subst "${PARAM_SSH_KEX_ALGORITHMS}")
SSH_KEY_FINGERPRINT=$(subst "${PARAM_FINGERPRINT}")
SSH_KNOWN_HOSTS=$(subst "${PARAM_SSH_KNOWN_HOSTS}")
SUBMODULES=$(subst "${PARAM_SUBMODULES}")

case "${DEPTH}" in
    full | shallow | empty) ;;
    *)
        echo "ERROR: depth must be full, shallow or empty, not '${DEPTH}'." >&2
        exit 1
        ;;
esac
case "${SUBMODULES}" in
    none | recursive | recursive-shallow | top-level | top-level-shallow) ;;
    *)
        echo "ERROR: submodules must be none, recursive, recursive-shallow, top-level or top-level-shallow, not '${SUBMODULES}'." >&2
        exit 1
        ;;
esac
if [[ "${DEPTH}" == "empty" && "${SUBMODULES}" != "none" ]]; then
    echo "ERROR: Submodules cannot be checked out when depth is empty." >&2
    exit 1
fi
ssh_value ssh_ciphers "${SSH_CIPHERS}"
ssh_value ssh_fingerprint_hash "${SSH_FINGERPRINT_HASH}"
ssh_value ssh_host_key_algorithms "${SSH_HOST_KEY_ALGORITHMS}"
ssh_value ssh_kex_algorithms "${SSH_KEX_ALGORITHMS}"

echo "The following parameters are being used:"
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH:-}"
echo "  CIRCLE_REPOSITORY_URL: ${CIRCLE_REPOSITORY_URL:-}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1:-}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG:-}"
echo "  DEPTH: ${DEPTH}"
echo "  SSH_ACCEPT_NEW_HOST_KEY: ${SSH_ACCEPT_NEW_HOST_KEY}"
echo "  SSH_CIPHERS: ${SSH_CIPHERS}"
echo "  SSH_FINGERPRINT_HASH: ${SSH_FINGERPRINT_HASH}"
echo "  SSH_HOST_KEY_ALGORITHMS: ${SSH_HOST_KEY_ALGORITHMS}"
echo "  SSH_KEX_ALGORITHMS: ${SSH_KEX_ALGORITHMS}"
echo "  SSH_KEY_FINGERPRINT: ${SSH_KEY_FINGERPRINT}"
echo "  SUBMODULES: ${SUBMODULES}"

# The repository's SSH user, host and port, from CIRCLE_REPOSITORY_URL in any
# of the forms git takes: user@host:path, ssh://user@host[:port]/path, or an
# https:// URL, which is cloned over SSH as git@host:path.
REPOSITORY_URL=${CIRCLE_REPOSITORY_URL:-}
SSH_PORT=22
case "${REPOSITORY_URL}" in
    ssh://*)
        CLONE_URL=${REPOSITORY_URL}
        AUTHORITY=${REPOSITORY_URL#ssh://}
        AUTHORITY=${AUTHORITY%%/*}
        SSH_USER=git
        if [[ "${AUTHORITY}" == *@* ]]; then
            SSH_USER=${AUTHORITY%@*}
            AUTHORITY=${AUTHORITY##*@}
        fi
        SSH_HOST=${AUTHORITY%%:*}
        if [[ "${AUTHORITY}" == *:* ]]; then
            SSH_PORT=${AUTHORITY##*:}
        fi
        ;;
    https://*)
        URL_PATH=${REPOSITORY_URL#https://}
        SSH_HOST=${URL_PATH%%/*}
        SSH_HOST=${SSH_HOST##*@}
        SSH_HOST=${SSH_HOST%%:*}
        URL_PATH=${URL_PATH#*/}
        SSH_USER=git
        CLONE_URL="git@${SSH_HOST}:${URL_PATH}"
        ;;
    *@*:*)
        CLONE_URL=${REPOSITORY_URL}
        SSH_USER=${REPOSITORY_URL%%@*}
        SSH_HOST=${REPOSITORY_URL#*@}
        SSH_HOST=${SSH_HOST%%:*}
        ;;
    *)
        echo "ERROR: CIRCLE_REPOSITORY_URL is '${REPOSITORY_URL}', not a repository URL such as git@github.com:org/repo.git." >&2
        exit 1
        ;;
esac
if ! c_match "${SSH_HOST}" '^[A-Za-z0-9.-]+$' || ! c_match "${SSH_USER}" '^[A-Za-z0-9._-]+$' ||
    ! c_match "${SSH_PORT}" '^[0-9]+$'; then
    echo "ERROR: Can't read the SSH user, host and port from CIRCLE_REPOSITORY_URL '${REPOSITORY_URL}'." >&2
    exit 1
fi
# known_hosts names a host on another port as [host]:port.
KNOWN_HOST=${SSH_HOST}
if [[ "${SSH_PORT}" != 22 ]]; then
    KNOWN_HOST="[${SSH_HOST}]:${SSH_PORT}"
fi
echo "Computed SSH host: ${KNOWN_HOST}"
echo "Computed clone URL: ${CLONE_URL}"

# The commit to check out. CIRCLE_SHA1 is always set in a pipeline; the tag
# and branch are fallbacks.
if [[ -n "${CIRCLE_SHA1:-}" ]]; then
    CHECKOUT_REF=${CIRCLE_SHA1}
elif [[ -n "${CIRCLE_TAG:-}" ]]; then
    CHECKOUT_REF=${CIRCLE_TAG}
elif [[ -n "${CIRCLE_BRANCH:-}" ]]; then
    CHECKOUT_REF=${CIRCLE_BRANCH}
else
    echo "ERROR: CIRCLE_SHA1, CIRCLE_TAG and CIRCLE_BRANCH are all empty, so there is nothing to check out." >&2
    exit 1
fi
echo "Computed CHECKOUT_REF: ${CHECKOUT_REF}"

# The key file add_ssh_keys wrote for the fingerprint. CircleCI names it
# ~/.ssh/id_rsa_<MD5 fingerprint without colons> whatever the key type, so a
# SHA256 fingerprint is matched against each key's own.
SSH_KEY_FILE=""
if [[ "${SSH_KEY_FINGERPRINT}" == SHA256:* ]]; then
    if ! command -v ssh-keygen > /dev/null 2>&1; then
        echo "ERROR: ssh-keygen is required to find the key for a SHA256 fingerprint but is not installed." >&2
        exit 1
    fi
    echo "Searching for the key file with fingerprint ${SSH_KEY_FINGERPRINT}..."
    for keyfile in "${HOME}"/.ssh/id_*; do
        if [[ ! -f "${keyfile}" || "${keyfile}" == *.pub ]]; then
            continue
        fi
        KEY_FINGERPRINT=$(ssh-keygen -l -E sha256 -f "${keyfile}" 2> /dev/null | awk '{print $2}' || true)
        echo "  ${keyfile}: ${KEY_FINGERPRINT:-not a key}"
        if [[ "${KEY_FINGERPRINT}" == "${SSH_KEY_FINGERPRINT}" ]]; then
            SSH_KEY_FILE=${keyfile}
            break
        fi
    done
    if [[ -z "${SSH_KEY_FILE}" ]]; then
        echo "ERROR: No key in ${HOME}/.ssh has the fingerprint ${SSH_KEY_FINGERPRINT}. Check that it is one of the project's additional SSH keys." >&2
        exit 1
    fi
elif [[ -n "${SSH_KEY_FINGERPRINT}" ]]; then
    # CircleCI shows MD5 fingerprints in lowercase, and names the file so.
    MD5_FINGERPRINT=${SSH_KEY_FINGERPRINT#MD5:}
    MD5_FINGERPRINT=${MD5_FINGERPRINT,,}
    if ! c_match "${MD5_FINGERPRINT}" '^([0-9a-f]{2}:){15}[0-9a-f]{2}$'; then
        echo "ERROR: fingerprint must be a SHA256:... or MD5 (aa:bb:...) fingerprint, not '${SSH_KEY_FINGERPRINT}'." >&2
        exit 1
    fi
    SSH_KEY_FILE="${HOME}/.ssh/id_rsa_${MD5_FINGERPRINT//:/}"
    if [[ ! -f "${SSH_KEY_FILE}" ]]; then
        echo "ERROR: ${SSH_KEY_FILE} does not exist. Check that ${SSH_KEY_FINGERPRINT} is one of the project's additional SSH keys." >&2
        exit 1
    fi
fi
if [[ -n "${SSH_KEY_FILE}" ]]; then
    echo "Computed SSH_KEY_FILE: ${SSH_KEY_FILE}"
fi

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
touch "${KNOWN_HOSTS_FILE}"

# add_known_hosts LINES: appends each line of LINES that the known_hosts
# file doesn't hold yet.
add_known_hosts() {
    local line
    while IFS= read -r line; do
        if [[ -n "${line}" ]] && ! grep -qxF -- "${line}" "${KNOWN_HOSTS_FILE}"; then
            printf '%s\n' "${line}" >> "${KNOWN_HOSTS_FILE}"
        fi
    done <<< "$1"
}

# known_host_listed FILE: succeeds if FILE holds a key for the host, hashed
# host names included.
known_host_listed() {
    [[ -f "$1" ]] && command -v ssh-keygen > /dev/null 2>&1 &&
        ssh-keygen -F "${KNOWN_HOST}" -f "$1" > /dev/null 2>&1
}

SCAN_FILE=""
cleanup() {
    if [[ -n "${SCAN_FILE}" ]]; then
        rm -f "${SCAN_FILE}"
    fi
}
trap cleanup EXIT

if [[ -n "${SSH_KNOWN_HOSTS}" ]]; then
    echo "Adding the host keys in ssh_known_hosts to ${KNOWN_HOSTS_FILE}."
    add_known_hosts "${SSH_KNOWN_HOSTS}"
    if command -v ssh-keygen > /dev/null 2>&1 && ! known_host_listed "${KNOWN_HOSTS_FILE}"; then
        echo "WARN: No line in ssh_known_hosts names ${KNOWN_HOST}, so ssh will refuse its host key." >&2
    fi
elif [[ "${KNOWN_HOST}" == "github.com" ]]; then
    echo "Adding GitHub's published host keys to ${KNOWN_HOSTS_FILE}."
    add_known_hosts "${GITHUB_KNOWN_HOSTS}"
elif known_host_listed "${KNOWN_HOSTS_FILE}" || known_host_listed /etc/ssh/ssh_known_hosts; then
    echo "Using the host keys for ${KNOWN_HOST} already in the image's known_hosts."
elif [[ "${SSH_ACCEPT_NEW_HOST_KEY}" == true ]]; then
    # ssh records the key the server presents before it authenticates, with
    # the same algorithms git will use. ssh-keyscan would not do: with FIPS
    # mode on, as on RHEL 9, it fails to negotiate a key exchange.
    echo "WARN: Trusting the host key ${KNOWN_HOST} presents now (ssh_accept_new_host_key), without checking it." >&2
    SCAN_FILE=$(mktemp)
    SCAN_OUTPUT=$(ssh -o BatchMode=yes \
        -o ConnectTimeout=30 \
        -o PubkeyAuthentication=no \
        -o "KexAlgorithms=${SSH_KEX_ALGORITHMS}" \
        -o "HostKeyAlgorithms=${SSH_HOST_KEY_ALGORITHMS}" \
        -o "Ciphers=${SSH_CIPHERS}" \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=${SCAN_FILE}" \
        -p "${SSH_PORT}" \
        "${SSH_USER}@${SSH_HOST}" exit 2>&1 || true)
    if [[ ! -s "${SCAN_FILE}" ]]; then
        echo "ERROR: ${KNOWN_HOST} presented no host key ssh accepts with these algorithms. ssh said:" >&2
        printf '%s\n' "${SCAN_OUTPUT}" >&2
        exit 1
    fi
    echo "Recorded the host key:"
    cat "${SCAN_FILE}"
    add_known_hosts "$(cat "${SCAN_FILE}")"
else
    echo "ERROR: No host key is known for ${KNOWN_HOST}, so its identity can't be checked." >&2
    echo "ERROR: Set ssh_known_hosts to its known_hosts lines (ssh-keyscan from a trusted machine, or from its administrator)," >&2
    echo "ERROR: or set ssh_accept_new_host_key to true to trust the key it presents." >&2
    exit 1
fi

# git runs GIT_SSH_COMMAND with sh, so every word is quoted for the shell.
SSH_COMMAND=(ssh
    -o "KexAlgorithms=${SSH_KEX_ALGORITHMS}"
    -o "HostKeyAlgorithms=${SSH_HOST_KEY_ALGORITHMS}"
    -o "Ciphers=${SSH_CIPHERS}"
    -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}"
    -o "FingerprintHash=${SSH_FINGERPRINT_HASH}"
    -o ForwardAgent=no
    -o ForwardX11=no)
# A key file is used on its own, so ssh-agent's keys are never offered.
if [[ -n "${SSH_KEY_FILE}" ]]; then
    SSH_COMMAND+=(-o IdentitiesOnly=yes -o IdentityAgent=none -o "IdentityFile=${SSH_KEY_FILE}")
fi
GIT_SSH_COMMAND=$(printf '%q ' "${SSH_COMMAND[@]}")
GIT_SSH_COMMAND=${GIT_SSH_COMMAND% }
export GIT_SSH_COMMAND
echo "Computed GIT_SSH_COMMAND: ${GIT_SSH_COMMAND}"
if [[ -n "${BASH_ENV:-}" ]]; then
    printf 'export %s=%q\n' GIT_SSH_COMMAND "${GIT_SSH_COMMAND}" >> "${BASH_ENV}"
fi

# https URLs of the repository's host go over SSH too, with the same key: Go
# modules, and submodules listed by https URL.
if [[ "${CONFIGURE_GIT_SSH}" == true ]]; then
    SSH_BASE="ssh://${SSH_USER}@${SSH_HOST}/"
    if [[ "${SSH_PORT}" != 22 ]]; then
        SSH_BASE="ssh://${SSH_USER}@${SSH_HOST}:${SSH_PORT}/"
    fi
    git config --global "url.${SSH_BASE}.insteadOf" "https://${SSH_HOST}/"
    echo "Configured git to fetch https://${SSH_HOST}/ over SSH."
fi

echo "Checking out ${CHECKOUT_REF} with depth ${DEPTH}..."
case "${DEPTH}" in
    full)
        if ! git clone -- "${CLONE_URL}" .; then
            echo "ERROR: git clone failed." >&2
            exit 1
        fi
        if ! git checkout "${CHECKOUT_REF}"; then
            echo "ERROR: git checkout of ${CHECKOUT_REF} failed." >&2
            exit 1
        fi
        ;;
    shallow)
        if ! git init . || ! git remote add origin "${CLONE_URL}"; then
            echo "ERROR: Setting up the repository failed." >&2
            exit 1
        fi
        if ! git fetch --depth 1 origin "${CHECKOUT_REF}"; then
            echo "ERROR: git fetch of ${CHECKOUT_REF} failed." >&2
            exit 1
        fi
        if ! git checkout FETCH_HEAD; then
            echo "ERROR: git checkout of ${CHECKOUT_REF} failed." >&2
            exit 1
        fi
        ;;
    empty)
        if ! git clone --no-checkout -- "${CLONE_URL}" .; then
            echo "ERROR: git clone failed." >&2
            exit 1
        fi
        ;;
esac

if [[ "${SUBMODULES}" != "none" ]]; then
    echo "Checking out submodules (${SUBMODULES})..."
    SUBMODULE_ARGS=(--init)
    case "${SUBMODULES}" in
        recursive) SUBMODULE_ARGS+=(--recursive) ;;
        recursive-shallow) SUBMODULE_ARGS+=(--recursive --depth=1) ;;
        top-level-shallow) SUBMODULE_ARGS+=(--depth=1) ;;
    esac
    if ! git submodule update "${SUBMODULE_ARGS[@]}"; then
        echo "ERROR: git submodule update failed." >&2
        exit 1
    fi
fi
echo "Checkout completed."
