#!/bin/bash

set -euo pipefail
set +o history
IFS=$'\n\t'

# Check that required software is installed.
# This orb can be used in a wide variety of containers, so we need to check.
# Non-cimg container images do not have the CircleCI CLI tool installed.
# Other containers such as ubi9+ do not have ssh installed by default.
REQUIRED_COMMANDS=("ssh" "ssh-keygen" "git" "awk" "cut" "tr" "touch" "rm" "mkdir" "mktemp" "unset" "echo")
for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" > /dev/null; then
        echo "FATAL: Command '$CMD' is required but not installed."
        exit 1
    fi
done
if ! command -v circleci &> /dev/null; then
    echo "WARN: The CircleCI CLI tool is not installed. Environment variables will not be expanded."
fi

# Check that required parameters were supplied
# This means that the variables must be non-empty from the perspective of *this* script.
# They can still be optional orb parameters if default values are provided.
REQUIRED_PARAMS=("PARAM_CONFIGURE_GIT_SSH" "PARAM_DEPTH" "PARAM_SUBMODULES")
for PARAM in "${REQUIRED_PARAMS[@]}"; do
    if [[ -z "${!PARAM:-}" ]]; then
        echo "FATAL: Param '$PARAM' is required but not set."
        exit 1
    fi
done

# Read in the orb parameters
if command -v circleci &> /dev/null; then
    CONFIGURE_GIT_SSH=$(circleci env subst "$PARAM_CONFIGURE_GIT_SSH")
    DEPTH=$(circleci env subst "$PARAM_DEPTH")
    SSH_CIPHERS=$(circleci env subst "$PARAM_SSH_CIPHERS")
    SSH_FINGERPRINT_HASH=$(circleci env subst "$PARAM_SSH_FINGERPRINT_HASH")
    SSH_HOST_KEY_ALGORITHMS=$(circleci env subst "$PARAM_SSH_HOST_KEY_ALGORITHMS")
    SSH_KEX_ALGORITHMS=$(circleci env subst "$PARAM_SSH_KEX_ALGORITHMS")
    SSH_KEY_FINGERPRINT=$(circleci env subst "$PARAM_FINGERPRINT")
    SUBMODULES=$(circleci env subst "$PARAM_SUBMODULES")
else
    CONFIGURE_GIT_SSH="$PARAM_CONFIGURE_GIT_SSH"
    DEPTH="$PARAM_DEPTH"
    SSH_CIPHERS="$PARAM_SSH_CIPHERS"
    SSH_FINGERPRINT_HASH="$PARAM_SSH_FINGERPRINT_HASH"
    SSH_HOST_KEY_ALGORITHMS="$PARAM_SSH_HOST_KEY_ALGORITHMS"
    SSH_KEX_ALGORITHMS="$PARAM_SSH_KEX_ALGORITHMS"
    SSH_KEY_FINGERPRINT="$PARAM_FINGERPRINT"
    SUBMODULES="$PARAM_SUBMODULES"
fi

# Input validation of parameter values
VALID_SUBMODULES=("none" "recursive" "recursive-shallow" "top-level" "top-level-shallow")
if [[ ! " ${VALID_SUBMODULES[*]} " =~ ${SUBMODULES} ]]; then
    echo "FATAL: Invalid SUBMODULES value '${SUBMODULES}'. Must be one of: ${VALID_SUBMODULES[*]}"
    exit 1
fi
VALID_DEPTH=("empty" "shallow" "full")
if [[ ! " ${VALID_DEPTH[*]} " =~ ${DEPTH} ]]; then
    echo "FATAL: Invalid DEPTH value '${DEPTH}'. Must be one of: ${VALID_DEPTH[*]}"
    exit 1
fi

# Input validation of parameter combinations
if [[ "${DEPTH}" == "empty" && "${SUBMODULES}" != "none" ]]; then
    echo "FATAL: Submodules cannot be checked out when the depth parameter is set to 'empty'."
    exit 1
fi

# Print orb parameters for debugging purposes
echo "The following parameters are being used:"
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH:-}"
echo "  CIRCLE_REPOSITORY_URL: ${CIRCLE_REPOSITORY_URL:-}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1:-}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG:-}"
echo "  DEPTH: ${DEPTH:-}"
echo "  SSH_CIPHERS: ${SSH_CIPHERS:-}"
echo "  SSH_FINGERPRINT_HASH: ${SSH_FINGERPRINT_HASH:-}"
echo "  SSH_HOST_KEY_ALGORITHMS: ${SSH_HOST_KEY_ALGORITHMS:-}"
echo "  SSH_KEX_ALGORITHMS: ${SSH_KEX_ALGORITHMS:-}"
echo "  SSH_KEY_FINGERPRINT: ${SSH_KEY_FINGERPRINT:-}"
echo "  SUBMODULES: ${SUBMODULES:-}"

# Extract the GitHub domain name from the CIRCLE_REPOSITORY_URL.
# Input format: git@<GH_HOST>:<ORG>/<REPO>
# Extracted format: <GH_HOST>
GH_HOST=$(echo "$CIRCLE_REPOSITORY_URL" | cut -d':' -f1 | cut -d'@' -f2)
echo "Computed GH_HOST: ${GH_HOST}"

# Compute checkout reference.
# In theory CIRLCE_SHA1 should always be set, but extra checks are added for safety.
if [[ -n "${CIRCLE_SHA1:-}" ]]; then
    CHECKOUT_REF="${CIRCLE_SHA1}"
elif [[ -n "${CIRCLE_TAG:-}" ]]; then
    CHECKOUT_REF="${CIRCLE_TAG}"
elif [[ -n "${CIRCLE_BRANCH:-}" ]]; then
    CHECKOUT_REF="${CIRCLE_BRANCH}"
else
    echo "FATAL: Unable to determine the checkout reference."
    exit 1
fi
echo "Computed CHECKOUT_REF: ${CHECKOUT_REF}"

SSH_KEY_FILE=""
if [[ -n "$SSH_KEY_FINGERPRINT" ]]; then
    # When a fingerprint is provided, we need to locate the corresponding SSH key file.
    # CircleCI always prefixes "id_rsa" in the file name, even if the key is not RSA based
    # Input example (MD5 format): "e8:35:14:20:8c:57:a3:68:b3:6e:cc:3d:b8:72:bf:88"
    # Input example (SHA-256 format): "SHA256:NPj4IcXxqQEKGXOghi/QbG2sohoNfvZ30JwCcdSSNM0"
    # Extracted format: ~/.ssh/id_rsa_<fingerprint>
    SSH_KEY_FILE=""
    if [[ "$SSH_KEY_FINGERPRINT" == SHA256:* ]]; then
        SSH_KEY_FINGERPRINT_FLAT=$(echo "$SSH_KEY_FINGERPRINT" | cut -d ':' -f2)
        echo "Searching for key file with fingerprint: $SSH_KEY_FINGERPRINT_FLAT"
        for keyfile in ~/.ssh/id_*; do
        if [[ -f "$keyfile" && ! "$keyfile" =~ \.pub$ ]]; then
            FINGERPRINT=$(ssh-keygen -lf "$keyfile" | awk '{print $2}')
            echo "  File $keyfile has fingerprint: $FINGERPRINT"
            if [[ "$FINGERPRINT" == "$SSH_KEY_FINGERPRINT" ]]; then
                echo "  Found keyfile matching supplied fingerprint: $keyfile"
                SSH_KEY_FILE="$keyfile"
            fi
        fi
        done
        if [[ -z "$SSH_KEY_FILE" ]]; then
            echo "FATAL: Failed to locate the SSH key file based on the provided SHA256 fingerprint."
            exit 1
        fi
    else
        # If the fingerprint doesn't start with "SHA256:", then it must be in the old MD5 format used by CircleCI.
        # Ref: https://circleci.com/docs/add-ssh-key/#add-ssh-keys-to-a-job
        SSH_KEY_FINGERPRINT_FLAT=$(echo "$SSH_KEY_FINGERPRINT" | tr -d ':')
        SSH_KEY_FILE="$HOME/.ssh/id_rsa_$SSH_KEY_FINGERPRINT_FLAT"

        if [[ ! -f "$SSH_KEY_FILE" ]]; then
            echo "FATAL: Unable to locate the SSH key file based on the provided MD5 fingerprint."
            exit 1
        fi
    fi

    if [[ -z "$SSH_KEY_FILE" ]]; then
        echo "WARN: Unable to locate the SSH key file based on the provided fingerprint."
    else
        echo "Computed SSH_KEY_FINGERPRINT_FLAT: ${SSH_KEY_FINGERPRINT_FLAT}"
        echo "Computed SSH_KEY_FILE: ${SSH_KEY_FILE}"
    fi
fi

# Use ssh-keyscan to get the known host entry.
if command -v ssh-keyscan &> /dev/null; then
    echo "Attempting to set up the known hosts file automatically."
    mkdir -p "$HOME/.ssh"
    SSH_KNOWN_HOST_ENTRY=$(ssh-keyscan -t "$SSH_HOST_KEY_ALGORITHMS" "$GH_HOST" || true)
    if [[ -n "$SSH_KNOWN_HOST_ENTRY" ]]; then
        echo "The ssh-keyscan command was successful."
        echo "  Found: $SSH_KNOWN_HOST_ENTRY"
        echo "  Adding to: $HOME/.ssh/known_hosts..."
        echo "$SSH_KNOWN_HOST_ENTRY" >> "$HOME/.ssh/known_hosts"
    else
        echo "The ssh-keyscan command failed."
    fi
fi

# If the ssh-keyscan fails with an error about an invalid key exchange type
# due to the use of FIPS mode, then we need to use an alternate workaround.
# This is a confirmed issue in RHEL 9 and ubi9. This clever workaround allows us
# to scan the remote server key using ssh instead of ssh-keyscan.
if [[ -z "$SSH_KNOWN_HOST_ENTRY" ]]; then
    echo "Attempting to scan the remote server key using ssh instead of ssh-keyscan."

    TEMP_KNOWN_HOSTS=$(mktemp)

    ssh -o KexAlgorithms="${SSH_KEX_ALGORITHMS}" \
        -o HostKeyAlgorithms="${SSH_HOST_KEY_ALGORITHMS}" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="${TEMP_KNOWN_HOSTS}" \
        "$GH_HOST" exit || true

    SSH_KNOWN_HOST_ENTRY=$(cat "${TEMP_KNOWN_HOSTS}")
    if [[ -n "$SSH_KNOWN_HOST_ENTRY" ]]; then
        echo "The ssh command was successful."
        echo "  Found: $SSH_KNOWN_HOST_ENTRY"
        echo "  Adding to: $HOME/.ssh/known_hosts..."
        mkdir -p "$HOME/.ssh"
        echo "$SSH_KNOWN_HOST_ENTRY" >> "$HOME/.ssh/known_hosts"
    fi

    rm "${TEMP_KNOWN_HOSTS}"
fi

# If the known host entry is still not available, then we must fail.
if [[ -z "$SSH_KNOWN_HOST_ENTRY" ]]; then
    echo "Failed to set up the SSH known hosts file."
    exit 1
fi

# Clone the git respository using the provided SSH key and secure, FIPS-approved SSH settings
echo "Running git clone using ssh..."

# If we have an SSH key file on disk, use it directly and specify IdentitiesOnly=yes with IdentityAgent=none to
# prevent ssh-agent from being used. This is only on disk if the built-in CircleCI checkout command was used OR
# if the user provided a fingerprint and we ran the add_ssh_keys command before calling this script. In all other
# cases, the key is in ssh-agent that we're able to access due to SSH_AUTH_SOCK being set.
if [[ -n "${SSH_KEY_FILE}" ]]; then
    export SSH_AUTH_SOCK=""
    SSH_KEY_ARGS="-o IdentitiesOnly=yes -o IdentityAgent=none -o IdentityFile=${SSH_KEY_FILE}"
else
    SSH_KEY_ARGS=""
fi
export GIT_SSH_COMMAND="ssh -o KexAlgorithms=${SSH_KEX_ALGORITHMS} -o HostKeyAlgorithms=${SSH_HOST_KEY_ALGORITHMS} -o Ciphers=${SSH_CIPHERS} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${HOME}/.ssh/known_hosts -o FingerprintHash=${SSH_FINGERPRINT_HASH} -o ForwardAgent=no -o ForwardX11=no ${SSH_KEY_ARGS:-}"
echo "Computed SSH_KEY_ARGS: ${SSH_KEY_ARGS:-}"
echo "Computed GIT_SSH_COMMAND: ${GIT_SSH_COMMAND:-}"
echo "export GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-}\"" >> "$BASH_ENV"

echo "Cloning the repository with depth: ${DEPTH}..."
if [[ "${DEPTH}" == "full" ]]; then
    echo "Cloning repository '${CIRCLE_REPOSITORY_URL}'..."
    if ! git clone "$CIRCLE_REPOSITORY_URL" .; then
        echo "FATAL: git clone failed."
        exit 1
    fi
    echo "Checking out reference '${CHECKOUT_REF}'..."
    if ! git checkout "${CHECKOUT_REF}"; then
        echo "FATAL: git checkout failed."
        exit 1
    fi
elif [[ "${DEPTH}" == "shallow" ]]; then
    echo "Initializing git repository..."
    if ! git init .; then
        echo "FATAL: git init failed."
        exit 1
    fi

    echo "Adding remote origin '${CIRCLE_REPOSITORY_URL}'..."
    if ! git remote add origin "${CIRCLE_REPOSITORY_URL}"; then
        echo "FATAL: git remote add failed."
        exit 1
    fi

    echo "Fetching reference '${CHECKOUT_REF}' with depth 1..."
    if ! git fetch --depth 1 origin "${CHECKOUT_REF}"; then
        echo "FATAL: git fetch failed."
        exit 1
    fi

    echo "Checking out source code for '${CHECKOUT_REF}'..."
    if ! git checkout FETCH_HEAD; then
        echo "FATAL: git checkout failed."
        exit 1
    fi
elif [[ "${DEPTH}" == "empty" ]]; then
    echo "Cloning git repository without source code..."
    if ! git clone --no-checkout "$CIRCLE_REPOSITORY_URL"; then
        echo "FATAL: git clone failed."
        exit 1
    fi
else
    echo "FATAL: Unknown depth parameter value: ${DEPTH}"
    exit 1
fi

# Checkout submodules if requested
if [[ "${SUBMODULES}" != "none" ]]; then
    echo "Checking out submodules for '${CHECKOUT_REF}'..."

    SUBMODULES_ARG=()
    if [[ "${SUBMODULES}" == "recursive" ]]; then
        SUBMODULES_ARG=(--init --recursive)
    elif [[ "${SUBMODULES}" == "recursive-shallow" ]]; then
        SUBMODULES_ARG=(--init --recursive --depth=1)
    elif [[ "${SUBMODULES}" == "top-level" ]]; then
        SUBMODULES_ARG=(--init)
    elif [[ "${SUBMODULES}" == "top-level-shallow" ]]; then
        SUBMODULES_ARG=(--init --depth=1)
    fi

    if ! git submodule update "${SUBMODULES_ARG[@]}"; then
        echo "FATAL: git submodule update failed."
        exit 1
    fi
fi

if [[ "${CONFIGURE_GIT_SSH}" == "1" ]]; then
    echo "Configuring git to use SSH instead of HTTPS..."
    if command -v git; then
        git config --global url."ssh://git@${GH_HOST}/".insteadOf "https://${GH_HOST}/"
        echo "Git has been configured."
    else
        echo "WARN: Parameter 'configure_git_ssh' was set to 'true', but the git command is not available."
    fi
fi
echo "FIPS-compliant code checkout completed."

# Cleanup
echo "Cleaning up input parameters..."
unset PARAM_CONFIGURE_GIT_SSH
unset PARAM_DEPTH
unset PARAM_SSH_CIPHERS
unset PARAM_SSH_FINGERPRINT_HASH
unset PARAM_SSH_HOST_KEY_ALGORITHMS
unset PARAM_SSH_KEX_ALGORITHMS
unset PARAM_SSH_KEY_FINGERPRINT
unset PARAM_SUBMODULES
echo "  Done."
