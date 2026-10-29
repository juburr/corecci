#!/bin/bash
#
# Installs ssh and git with the image's package manager when either is
# missing, as in Rocky Linux, UBI or Debian images. The package manager is the
# first of apt-get, apk, dnf, microdnf and yum found, so any release of those
# distributions works, RHEL 10 and UBI minimal images included.

set -euo pipefail

log_versions() {
    ssh -V
    git --version
}

missing=()
for tool in ssh git; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        missing+=("${tool}")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    log_versions
    exit 0
fi
echo "Installing ${missing[*]}..."

manager=""
for candidate in apt-get apk dnf microdnf yum; do
    if command -v "${candidate}" > /dev/null 2>&1; then
        manager=${candidate}
        break
    fi
done
if [[ -z "${manager}" ]]; then
    echo "ERROR: ${missing[*]} must be installed, and no supported package manager (apt-get, apk, dnf, microdnf or yum) was found." >&2
    exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
    echo "WARN: Not running as root, so ${manager} may not be able to install packages." >&2
fi

packages=()
for tool in "${missing[@]}"; do
    case "${tool}:${manager}" in
        ssh:apt-get | ssh:apk) packages+=(openssh-client) ;;
        ssh:*) packages+=(openssh-clients) ;;
        git:*) packages+=(git) ;;
    esac
done

echo "Running ${manager} to install ${packages[*]}..."
case "${manager}" in
    apt-get)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
        ;;
    apk)
        apk add --no-cache "${packages[@]}"
        ;;
    *)
        "${manager}" install -y "${packages[@]}"
        ;;
esac

for tool in "${missing[@]}"; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: ${manager} finished, but ${tool} is still not on the PATH." >&2
        exit 1
    fi
done
log_versions
