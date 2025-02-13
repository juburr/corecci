#!/bin/bash

set -euo pipefail
set +o history
IFS=$'\n\t'

# Log the installed versions
log_versions() {
    ssh -V
    git --version
}

# Detects the Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case $ID in
            ubuntu)
                echo "ubuntu"
                return
                ;;
            alpine)
                echo "alpine"
                return
                ;;
            ubi)
                case $VERSION_ID in
                    "7"*) echo "el7" ;;
                    "8"*) echo "el8" ;;
                    "9"*) echo "el9" ;;
                esac
                return
                ;;
            rhel|centos|rocky|*)
                if [ -f /etc/redhat-release ]; then
                    if grep -q "release 7" /etc/redhat-release; then
                        echo "el7"
                    elif grep -q "release 8" /etc/redhat-release; then
                        echo "el8"
                    elif grep -q "release 9" /etc/redhat-release; then
                        echo "el9"
                    fi
                    return
                fi
                ;;
        esac
    fi
    echo "unknown"
}

# Gets the package name for the given tool and distribution
get_package_name() {
    local tool=$1
    local distro=$2

    case $tool in
        ssh)
            case $distro in
                ubuntu|alpine)
                    echo "openssh-client"
                    ;;
                el*)
                    echo "openssh-clients"
                    ;;
            esac
            ;;
        git)
            echo "git"
            ;;
    esac
}

# Installs the given package on the given distribution
install_package() {
    local tool=$1
    local distro=$2
    local package

    if command -v "${tool}" &>/dev/null; then
        echo "${tool} is already installed."
        return
    fi

    package=$(get_package_name "${tool}" "${distro}")

    echo "Installing ${tool} via ${package} on ${distro}..."

    case $distro in
        ubuntu)
            apt-get update && apt-get install -y "${package}"
            ;;
        alpine)
            apk add --no-cache "${package}"
            ;;
        el7)
            yum install -y "${package}"
            ;;
        el8|el9)
            dnf install -y "${package}"
            ;;
        *)
            echo "FATAL: Unable to install ${package} - unsupported distribution"
            exit 1
            ;;
    esac
}

# Bail out early if dependencies are already installed
if command -v git &>/dev/null && command -v ssh &>/dev/null; then
    log_versions
    exit 0
fi

# If we need to install dependencies, we may need to be root
if [ "$(id -u)" -ne 0 ]; then
    echo "WARN: This script may not work as expected unless run as root."
fi

# Detect the Linux distribution
LINUX_DISTRO=$(detect_distro)
if [ "$LINUX_DISTRO" = "unknown" ]; then
    echo "FATAL: Unable to detect Linux distribution; packages cannot be installed."
    exit 1
fi
echo "Detected Linux distribution: ${LINUX_DISTRO}"

# Install dependencies
install_package ssh "$LINUX_DISTRO"
install_package git "$LINUX_DISTRO"

# Log the installed versions
log_versions
