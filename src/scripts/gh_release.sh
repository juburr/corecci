#!/bin/bash

set -euo pipefail
set +o history
IFS=$'\n\t'

# Check that required software is installed.
# This orb can be used in a wide variety of containers, so we need to check.
# Non-cimg container images do not have the CircleCI CLI tool installed.
REQUIRED_COMMANDS=("gh" "echo" "grep" "unset")
for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" > /dev/null; then
        echo "FATAL: Command '$CMD' is required but not installed."
        exit 1
    fi
done
if ! command -v circleci &> /dev/null; then
    echo "WARN: The CircleCI CLI tool is not installed. Environment variables will not be expanded."
fi

# Read in the orb parameters
if command -v circleci &> /dev/null; then
    ARTIFACT_CHECKSUMS=$(circleci env subst "$PARAM_ARTIFACT_CHECKSUMS")
    ARTIFACT_MANIFEST=$(circleci env subst "$PARAM_ARTIFACT_MANIFEST")
    PROJECT_NAME=$(circleci env subst "$PARAM_PROJECT_NAME")
    RELEASE_NOTES=$(circleci env subst "$PARAM_RELEASE_NOTES")
else
    ARTIFACT_CHECKSUMS="${ARTIFACT_CHECKSUMS:-}"
    ARTIFACT_MANIFEST="${ARTIFACT_MANIFEST:-}"
    PROJECT_NAME="${PARAM_PROJECT_NAME:-}"
    RELEASE_NOTES="${PARAM_RELEASE_NOTES:-}"
fi

# Print orb parameters for debugging purposes
echo "The following parameters are being used:"
echo "  CIRCLE_PROJECT_USERNAME: ${CIRCLE_PROJECT_USERNAME:-}"
echo "  CIRCLE_PROJECT_REPONAME: ${CIRCLE_PROJECT_REPONAME:-}"
echo "  CIRCLE_TAG: ${CIRCLE_TAG:-}"
echo "  ARTIFACT_CHECKSUMS: ${ARTIFACT_CHECKSUMS:-}"
echo "  ARTIFACT_MANIFEST: ${ARTIFACT_MANIFEST:-}"
echo "  PROJECT_NAME: ${PROJECT_NAME:-}"
echo "  RELEASE_NOTES: ${RELEASE_NOTES:-}"

# Determine the checksum tool to use
# This also serves as input validation for the ARTIFACT_CHECKSUMS enum parameter.
CHECKSUM_TOOL=()
VALID_CHECKSUM_TOOLS=("none" "md5" "sha1" "sha256" "sha384" "sha512")
case "$ARTIFACT_CHECKSUMS" in
    "none")
        CHECKSUM_TOOL=()
        ;;
    "md5")
        CHECKSUM_TOOL=(md5sum)
        ;;
    "sha1")
        CHECKSUM_TOOL=(sha1sum)
        ;;
    "sha256")
        CHECKSUM_TOOL=(sha256sum)
        ;;
    "sha384")
        CHECKSUM_TOOL=(sha384sum)
        ;;
    "sha512")
        CHECKSUM_TOOL=(sha512sum)
        ;;
    *)
        echo "FATAL: Invalid ARTIFACT_CHECKSUMS value '${ARTIFACT_CHECKSUMS}'. Must be one of: ${VALID_CHECKSUM_TOOLS[*]}"
        exit 1
        ;;
esac

# Validate that the artifact manifest is a valid file
if [ -n "$ARTIFACT_MANIFEST" ]; then
    if [ ! -f "$ARTIFACT_MANIFEST" ]; then
        echo "FATAL: The provided artifact manifest file does not exist: $ARTIFACT_MANIFEST"
        exit 1
    fi

    # Load the artifact manifest into an associative array
    declare -A ARTIFACTS
    while IFS= read -r LINE; do
        # Skip empty lines
        if [ -z "$LINE" ]; then
            continue
        fi

        # Check if the artifact path is a valid file
        ARTIFACT_PATH="$LINE"
        if [ ! -f "$ARTIFACT_PATH" ]; then
            echo "FATAL: An artifact in the manifest has an invalid path that cannot be read: $ARTIFACT_PATH"
            exit 1
        fi

        # Calculate the checksum of the artifact
        ARTIFACT_HASH=""
        if [ -n "${CHECKSUM_TOOL[*]}" ]; then
            echo "Calculating checksum for $ARTIFACT_PATH using ${CHECKSUM_TOOL[*]}..."
            ARTIFACT_HASH=$("${CHECKSUM_TOOL[@]}" "$ARTIFACT_PATH" | cut -d ' ' -f 1)
            echo "  Checksum: $ARTIFACT_HASH"
        fi

        # Add the artifact to the associative array
        ARTIFACTS["$ARTIFACT_PATH"]="$ARTIFACT_HASH"
    done
fi

# Determine the release name
# Example: "CoreCCI v1.2.3"
if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="${CIRCLE_PROJECT_REPONAME}"
fi
RELEASE_NAME="${PROJECT_NAME} ${CIRCLE_TAG}"

# Calculate the repository name
# Example: "juburr/corecci"
REPO="${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"

# Determine if this is a pre-release
# This is determined if the semver tag includes "-alpha", "-beta", or "-rc".
# Example: "v1.2.3-alpha.1" -> "true"
# Example: "v1.2.3" -> "false"
IS_PRERELEASE=$(echo "$CIRCLE_TAG" | grep -E -- '-(alpha|beta|rc)' || true)
PRERELEASE_ARG=()
if [ -n "$IS_PRERELEASE" ]; then
    PRERELEASE_ARG=(--prerelease)
fi

# Determine if release notes should be auto-generated
if [ -n "$RELEASE_NOTES" ]; then
    echo "Using custom release notes."
    RELEASE_NOTES_ARG=(--notes "$RELEASE_NOTES")
else
    echo "Using auto-generated release notes."
    RELEASE_NOTES_ARG=(--generate-notes)
fi

# Create a release
echo "Creating the release..."
gh release create \
    --repo "$REPO" \
    --title "$RELEASE_NAME" \
    "${RELEASE_NOTES_ARG[@]}" \
    "${PRERELEASE_ARG[@]}" \
    "$CIRCLE_TAG"

# Loop through the artifact manifest and upload each file
for ARTIFACT_PATH in "${!ARTIFACTS[@]}"; do
    ARTIFACT_HASH="${ARTIFACTS[$ARTIFACT_PATH]}"
    ARTIFACT_BASE_NAME=$(basename "$ARTIFACT_PATH")
    echo "Uploading artifact: $ARTIFACT_PATH"

    gh release upload \
        --repo "$REPO" \
        --clobber \
        "$CIRCLE_TAG" \
        "$ARTIFACT_PATH#$ARTIFACT_BASE_NAME"
done

# Append the checksums to the release notes
# Doing this AFTER the release instead of combining into a --notes-file
# earlier is intentional and helpful because:
#  - The --generate-notes flag can still be used to create pretty release notes.
#  - The files have now been uploaded, so an upload failure won't leave stale entries.
if [ -n "$CHECKSUM_TOOL" ]; then
    echo "Appending checksums to the release notes..."
    RELEASE_NOTES_FILE=$(mktemp)

    # Fetch the original auto-generated release notes
    gh release view --repo "$REPO" "$CIRCLE_TAG" > "$RELEASE_NOTES_FILE"

    for ARTIFACT_PATH in "${!ARTIFACTS[@]}"; do
        ARTIFACT_HASH="${ARTIFACTS[$ARTIFACT_PATH]}"
        echo "  $ARTIFACT_PATH: $ARTIFACT_HASH"
        echo "$ARTIFACT_PATH: $ARTIFACT_HASH" >> "$RELEASE_NOTES_FILE"
    done

    echo "Final release notes:"
    cat "$RELEASE_NOTES_FILE"

    # Update the release notes with the checksums
    gh release edit \
        --repo "$REPO" \
        --clobber \
        --notes-file "$RELEASE_NOTES_FILE" \
        "$CIRCLE_TAG"

    rm "$RELEASE_NOTES_FILE"
fi

# Cleanup
echo "Cleaning up input parameters..."
unset PARAM_ARTIFACT_CHECKSUMS
unset PARAM_ARTIFACT_MANIFEST
unset PARAM_PROJECT_NAME
unset PARAM_RELEASE_NOTES
echo "  Done."
