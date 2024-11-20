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
REQUIRED_PARAMS=("PARAM_FINGERPRINT")
for PARAM in "${REQUIRED_PARAMS[@]}"; do
    if [[ -z "${!PARAM}" ]]; then
        echo "ERROR: Param '$PARAM' is required but not set."
        exit 1
    fi
done

# Read in the orb parameters
if command -v circleci &> /dev/null; then
    SSH_KEY_FINGERPRINT=$(circleci env subst "$PARAM_FINGERPRINT")
    SSH_CIPHERS=$(circleci env subst "$PARAM_SSH_CIPHERS")
    SSH_FINGERPRINT_HASH=$(circleci env subst "$PARAM_SSH_FINGERPRINT_HASH")
    SSH_HOST_KEY_ALGORITHMS=$(circleci env subst "$PARAM_SSH_HOST_KEY_ALGORITHMS")
    SSH_KEX_ALGORITHMS=$(circleci env subst "$PARAM_SSH_KEX_ALGORITHMS")
else
    SSH_KEY_FINGERPRINT="$PARAM_FINGERPRINT"
    SSH_CIPHERS="$PARAM_SSH_CIPHERS"
    SSH_FINGERPRINT_HASH="$PARAM_SSH_FINGERPRINT_HASH"
    SSH_HOST_KEY_ALGORITHMS="$PARAM_SSH_HOST_KEY_ALGORITHMS"
    SSH_KEX_ALGORITHMS="$PARAM_SSH_KEX_ALGORITHMS"
fi

# Extract the GitHub domain name from the CIRCLE_REPOSITORY_URL.
# Input format: git@<GH_HOST>:<ORG>/<REPO>
# Extracted format: <GH_HOST>
GH_HOST=$(echo "$CIRCLE_REPOSITORY_URL" | cut -d':' -f1 | cut -d'@' -f2)

# Locate the SSH key file based on the provided fingerprint
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
else
    SSH_KEY_FINGERPRINT_FLAT=$(echo "$SSH_KEY_FINGERPRINT" | tr -d ':')
    SSH_KEY_FILE="$HOME/.ssh/id_rsa_$SSH_KEY_FINGERPRINT_FLAT"
fi

if [[ -z "$SSH_KEY_FILE" ]]; then
  echo "Unable to locate the SSH key file based on the provided fingerprint."
  exit 1
fi

# Print orb parameters for debugging purposes
echo "The following parameters are being used:"
echo "  CIRCLE_BRANCH: ${CIRCLE_BRANCH:-}"
echo "  CIRCLE_REPOSITORY_URL: ${CIRCLE_REPOSITORY_URL:-}"
echo "  CIRCLE_SHA1: ${CIRCLE_SHA1:-}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG:-}"
echo "  GH_HOST: $GH_HOST"
echo "  SSH_CIPHERS: $SSH_CIPHERS"
echo "  SSH_FINGERPRINT_HASH: $SSH_FINGERPRINT_HASH"
echo "  SSH_HOST_KEY_ALGORITHMS: $SSH_HOST_KEY_ALGORITHMS"
echo "  SSH_KEX_ALGORITHMS: $SSH_KEX_ALGORITHMS"
echo "  SSH_KEY_FINGERPRINT: $SSH_KEY_FINGERPRINT"
echo "  SSH_KEY_FINGERPRINT_FLAT: $SSH_KEY_FINGERPRINT_FLAT"
echo "  SSH_KEY_FILE: $SSH_KEY_FILE"

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

# Checkout the git respository using the provided SSH key and secure, FIPS-approved SSH settings
echo "Running git clone using ssh..."
export GIT_SSH_COMMAND="ssh -o IdentitiesOnly=yes -o KexAlgorithms=${SSH_KEX_ALGORITHMS} -o HostKeyAlgorithms=${SSH_HOST_KEY_ALGORITHMS} -o Ciphers=${SSH_CIPHERS} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${HOME}/.ssh/known_hosts -o IdentityAgent=none -o IdentityFile=${SSH_KEY_FILE} -o FingerprintHash=${SSH_FINGERPRINT_HASH} -o ForwardAgent=no -o ForwardX11=no"
if ! git clone "$CIRCLE_REPOSITORY_URL" .; then
    echo "FATAL: git clone failed."
    exit 1
fi

# Ensure that we checkout the correct branch, tag, or commit required for this CircleCI job
echo "Checking out commit '${CIRCLE_SHA1:-}' for this job..."
if ! git checkout "${CIRCLE_SHA1:-}"; then
    echo "ERROR: git checkout failed. CIRCLE_SHA1 might not be set."

    # Attempt to checkout the associated branch if CIRCLE_SHA1 is not set
    echo "Checking out the branch '${CIRCLE_BRANCH:-}' for this job..."
    if ! git checkout "${CIRCLE_BRANCH:-}"; then
        echo "ERROR: git checkout failed. CIRCLE_BRANCH might not be set."
        exit 1
    fi

    # Attempt to checkout the associated tag if CIRCLE_BRANCH is not set
    echo "Checking out the tag '${CIRCLE_TAG:-}' for this job..."
    if ! git checkout "${CIRCLE_TAG:-}"; then
        echo "ERROR: git checkout failed. CIRCLE_TAG might not be set."
        exit 1
    fi
fi
echo "FIPS-compliant code checkout completed."

# Cleanup
echo "Cleaning up input parameters..."
unset PARAM_SSH_KEY_FINGERPRINT
unset PARAM_SSH_CIPHERS
unset PARAM_SSH_FINGERPRINT_HASH
unset PARAM_SSH_HOST_KEY_ALGORITHMS
unset PARAM_SSH_KEX_ALGORITHMS
echo "  Done."
