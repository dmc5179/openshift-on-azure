#!/usr/bin/env bash
#
# prereq.sh — install build dependencies for the custom OpenShift Azure IL6 release build.
#
# Target: RHEL 9 / x86_64 build host.
# Run as a normal user with passwordless sudo. Safe to re-run.
#
set -euo pipefail

#=============================================================================
# Pinned versions — override via environment
#=============================================================================

OC_VERSION="${OC_VERSION:-4.21.5}"
OC_MIRROR_CHANNEL="${OC_MIRROR_CHANNEL:-stable-4.22}"
INSTALLER_VERSION="${INSTALLER_VERSION:-4.21.1}"
GO_VERSION_MIN="${GO_VERSION_MIN:-1.24}"

MIRROR_BASE="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp"
DOCKER_REPO_URL="https://download.docker.com/linux/rhel/docker-ce.repo"
INSTALL_DIR="/usr/local/bin"

# Packages from the RHEL repos. golang 1.26.7 ships in RHEL 9.8 AppStream and
# matches the toolchain the release was originally built with.
DNF_PACKAGES=(
    dnf-plugins-core
    gcc
    git
    golang
    jq
    make
    podman
    python3-pip
    skopeo
    unzip
    wget
    zip
)

DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

#=============================================================================
# Output helpers
#=============================================================================

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn() { printf '%swarn%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s err%s %s\n' "${C_RED}"    "${C_RESET}" "$*" >&2; }

CHECK_FAILURES=0
note_missing() { err "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }

#=============================================================================
# Preflight
#=============================================================================

preflight() {
    log "Preflight checks"

    if [[ $EUID -eq 0 ]]; then
        err "Do not run as root. Run as a normal user with sudo access."
        err "Running as root puts the docker group membership and Go cache in the wrong place."
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        err "Passwordless sudo is required."
        exit 1
    fi
    ok "sudo available"

    local id_like=""
    [[ -r /etc/os-release ]] && id_like=$(. /etc/os-release && echo "${ID_LIKE:-$ID}")
    if [[ "${id_like}" != *rhel* && "${id_like}" != *fedora* ]]; then
        warn "Expected a RHEL 9 host; found '${id_like:-unknown}'. Continuing anyway."
    else
        ok "OS: $(. /etc/os-release && echo "${PRETTY_NAME}")"
    fi

    local arch
    arch=$(uname -m)
    if [[ "${arch}" != "x86_64" ]]; then
        err "This build requires x86_64; found ${arch}."
        exit 1
    fi
    ok "Arch: ${arch}"

    # The release build pulls ~200 images plus a full installer tree.
    local avail_gb
    avail_gb=$(df -BG --output=avail "${HOME}" | tail -1 | tr -dc '0-9')
    if (( avail_gb < 200 )); then
        warn "Only ${avail_gb}G free on ${HOME}. The mirror step alone needs ~150G."
    else
        ok "Disk: ${avail_gb}G available on ${HOME}"
    fi
}

#=============================================================================
# RHEL subscription
#
# The azure-disk-csi-driver image build runs `dnf install` inside the
# container, which needs entitlement certs bind-mounted from the host. RHUI
# certs do not work for this — the host must be registered with
# subscription-manager. Registration needs credentials, so this only reports.
#=============================================================================

entitlement_cert() {
    sudo test -d /etc/pki/entitlement || return 1
    local cert
    cert=$(sudo find /etc/pki/entitlement -name '*.pem' ! -name '*-key.pem' 2>/dev/null | head -1)
    [[ -n "${cert}" ]] && basename "${cert}" .pem
}

is_rhel() {
    [[ -r /etc/os-release ]] && [[ "$(. /etc/os-release && echo "${ID}")" == "rhel" ]]
}

check_subscription() {
    log "Checking RHEL subscription (needed for the azure-disk-csi-driver build)"

    local cert
    if cert=$(entitlement_cert); then
        ok "Entitlement cert present: ${cert}.pem"
        warn "Cert basenames are host-specific. The CSI driver Makefile and"
        warn "Dockerfile.openshift.rhel7 reference them by name and must be updated to match."
        return 0
    fi

    warn "No entitlement certificates found — the azure-disk-csi-driver build will fail."
    warn "Every other component builds fine without this."
    return 1
}

register_subscription() {
    if entitlement_cert >/dev/null; then
        return 0
    fi

    if ! is_rhel; then
        warn "Not RHEL — skipping subscription-manager registration."
        return 0
    fi

    if [[ ! -t 0 ]]; then
        warn "No TTY — cannot prompt for Red Hat credentials. Skipping registration."
        warn "Re-run from an interactive shell (ssh -t) to register."
        return 0
    fi

    log "Configuring this instance for RHN"
    cat <<'EOF'

  This host is not registered with Red Hat Subscription Management. Registering
  grants the container builds access to RHEL repos via entitlement certificates,
  which the azure-disk-csi-driver build requires.

  This will:
    1. Register with subscription-manager (prompts for your Red Hat login)
    2. Enable subscription-manager repo management
    3. Remove the AWS RHUI client and its repo files

  Note: this consumes a subscription entitlement and replaces RHUI as the
  package source for this host.

EOF
    read -r -p "  Register this host now? [y/N] " reply
    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
        warn "Skipped registration. The azure-disk-csi-driver build will fail without it."
        return 0
    fi

    # Register before tearing down RHUI: if the login fails, the host still has
    # a working package source instead of being stranded with no repos.
    echo
    log "Enter your Red Hat (RHN) credentials when prompted"
    if ! sudo subscription-manager register --force; then
        err "Registration failed. RHUI left intact — the host can still install packages."
        return 1
    fi
    ok "Registered with subscription-manager"

    sudo subscription-manager config --rhsm.manage_repos=1
    sudo dnf remove -y 'rh-amazon-rhui-client*' || true
    sudo rm -f /etc/yum.repos.d/redhat-rhui*.repo
    ok "Switched package source from RHUI to RHSM"

    local cert
    if cert=$(entitlement_cert); then
        ok "Entitlement cert now present: ${cert}.pem"
        warn "Update the CSI driver Makefile and Dockerfile.openshift.rhel7 to reference ${cert}.pem"
    else
        warn "Registered, but no entitlement cert appeared. Check: sudo subscription-manager status"
    fi
}

#=============================================================================
# Package installation
#=============================================================================

install_dnf_packages() {
    log "Installing base build packages"
    sudo dnf install -y "${DNF_PACKAGES[@]}"
    ok "Base packages installed"
}

install_docker() {
    log "Installing Docker CE"

    # cloud-provider-azure and azure-disk-csi-driver build with docker buildx,
    # not podman, so both runtimes are required.
    if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
        sudo dnf config-manager --add-repo "${DOCKER_REPO_URL}"
        ok "Added docker-ce repo"
    else
        ok "docker-ce repo already configured"
    fi

    sudo dnf install -y "${DOCKER_PACKAGES[@]}"
    sudo systemctl enable --now docker
    ok "Docker installed and running"

    if id -nG "${USER}" | grep -qw docker; then
        ok "${USER} is in the docker group"
    else
        sudo usermod -aG docker "${USER}"
        warn "Added ${USER} to the docker group — log out and back in before running docker."
    fi
}

install_python_yq() {
    log "Installing python-yq"

    # Two unrelated tools are named yq. The imageset-config generation uses
    # `yq -Y --arg`, which is python-yq (kislyuk) wrapping jq. The Go yq
    # (mikefarah) accepts neither flag and will silently produce a broken
    # imageset-config. Install the Python one and verify by behaviour.
    if ! yq_is_python; then
        pip3 install --user --upgrade yq
        ok "Installed python-yq via pip3"
    else
        ok "python-yq already present"
    fi

    if ! grep -qs 'HOME/.local/bin' "${HOME}/.bashrc"; then
        echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
        warn "Added ~/.local/bin to PATH in ~/.bashrc — source it or re-login."
    fi
}

yq_is_python() {
    local yq_bin
    yq_bin=$(command -v yq 2>/dev/null) || yq_bin="${HOME}/.local/bin/yq"
    [[ -x "${yq_bin}" ]] || return 1
    # The Go yq rejects -Y outright; python-yq round-trips this to YAML.
    echo '{"a":1}' | "${yq_bin}" -Y --arg k v '.b = $k' >/dev/null 2>&1
}

#=============================================================================
# OpenShift client binaries
#=============================================================================

# install_tarball <label> <url> <binary-glob> <versioned-name>
#
# Extracts the matching binary, installs it as <versioned-name>, and points an
# unversioned symlink at it so both `oc` and `oc-4.21.5` resolve.
install_tarball() {
    local label="$1" url="$2" glob="$3" versioned="$4"
    local link="${versioned%%-[0-9]*}"

    if [[ -x "${INSTALL_DIR}/${versioned}" ]]; then
        ok "${label} already installed (${versioned})"
        return 0
    fi

    log "Installing ${label} from ${url}"
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN

    if ! curl -fsSL --retry 3 -o "${tmp}/archive.tar.gz" "${url}"; then
        err "Download failed: ${url}"
        return 1
    fi
    tar -xzf "${tmp}/archive.tar.gz" -C "${tmp}"

    # The installer tarball ships openshift-install-fips, not openshift-install,
    # so match on a glob rather than an exact name. Do not filter on the
    # executable bit — oc-mirror extracts as mode 644.
    local found
    found=$(find "${tmp}" -maxdepth 2 -type f -name "${glob}" ! -name '*.tar.gz' | sort | head -1)
    if [[ -z "${found}" ]]; then
        err "No binary matching '${glob}' in the ${label} tarball. Contents:"
        find "${tmp}" -maxdepth 2 -type f -printf '      %f\n' >&2
        return 1
    fi

    sudo install -m 0755 "${found}" "${INSTALL_DIR}/${versioned}"
    if [[ "${link}" == "${versioned}" ]]; then
        ok "${label} -> ${INSTALL_DIR}/${versioned}"
    else
        sudo ln -sf "${INSTALL_DIR}/${versioned}" "${INSTALL_DIR}/${link}"
        ok "${label} -> ${INSTALL_DIR}/${versioned} (symlinked as ${link})"
    fi
}

install_openshift_clients() {
    log "Installing OpenShift client binaries"

    install_tarball "oc ${OC_VERSION}" \
        "${MIRROR_BASE}/${OC_VERSION}/openshift-client-linux-amd64-rhel9-${OC_VERSION}.tar.gz" \
        "oc" "oc-${OC_VERSION}"

    install_tarball "oc-mirror (${OC_MIRROR_CHANNEL})" \
        "${MIRROR_BASE}/${OC_MIRROR_CHANNEL}/oc-mirror.rhel9.tar.gz" \
        "oc-mirror" "oc-mirror"

    install_tarball "openshift-install ${INSTALLER_VERSION}" \
        "${MIRROR_BASE}/${INSTALLER_VERSION}/openshift-install-rhel9-amd64.tar.gz" \
        "openshift-install*" "openshift-install-fips-${INSTALLER_VERSION}"
}

#=============================================================================
# Verification
#=============================================================================

# Not every tool answers to --version: go wants `go version`, unzip wants -v.
probe_version() {
    case "$1" in
        go)    go version ;;
        unzip) unzip -v 2>/dev/null | head -1 ;;
        zip)   zip -v 2>/dev/null | grep -m1 -oP 'Zip \K[0-9.]+.*' ;;
        *)     "$1" --version 2>/dev/null | head -1 ;;
    esac
}

verify() {
    log "Verifying installation"

    local cmd
    for cmd in git make gcc go jq wget zip unzip podman skopeo docker; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            ok "$(printf '%-12s %s' "${cmd}" "$(probe_version "${cmd}")")"
        else
            note_missing "${cmd} is missing"
        fi
    done

    if command -v go >/dev/null 2>&1; then
        local go_ver
        go_ver=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
        if [[ "$(printf '%s\n%s\n' "${GO_VERSION_MIN}" "${go_ver}" | sort -V | head -1)" != "${GO_VERSION_MIN}" ]]; then
            note_missing "go ${go_ver} is older than the required ${GO_VERSION_MIN}"
        fi
    fi

    if yq_is_python; then
        ok "$(printf '%-12s %s' "yq" "python-yq ($(yq --version 2>&1 | head -1))")"
    else
        note_missing "yq is missing or is the Go build — imageset generation needs python-yq (pip3 install --user yq)"
    fi

    for cmd in "oc-${OC_VERSION}" oc-mirror "openshift-install-fips-${INSTALLER_VERSION}"; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            ok "$(printf '%-12s %s' "${cmd%%-[0-9]*}" "$("${cmd}" version --client 2>/dev/null | head -1 || echo installed)")"
        else
            note_missing "${cmd} is missing"
        fi
    done

    if systemctl is-active --quiet docker; then
        ok "docker service is running"
    else
        note_missing "docker service is not running"
    fi

    if ! id -nG "${USER}" | grep -qw docker; then
        warn "${USER} is not yet in the docker group in this shell — log out and back in."
    fi

    echo
    if (( CHECK_FAILURES == 0 )); then
        log "${C_GREEN}All build dependencies satisfied.${C_RESET}"
    else
        err "${CHECK_FAILURES} item(s) missing or wrong."
        return 1
    fi
}

#=============================================================================
# Main
#=============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Installs the build dependencies for the custom OpenShift Azure IL6 release
build on a RHEL 9 x86_64 host. Idempotent — safe to re-run.

Options:
  -c, --check         Verify only; install nothing. Exits non-zero if
                      anything is missing.
      --skip-docker   Skip Docker CE. Only do this if you are not building
                      cloud-provider-azure or azure-disk-csi-driver.
      --skip-register Do not offer to register with Red Hat Subscription
                      Management, even if the host is unregistered.
  -h, --help          Show this help.

On an unregistered RHEL host this prompts for your Red Hat (RHN) login and
registers with subscription-manager, which the azure-disk-csi-driver build
needs for entitlement certificates. Requires an interactive terminal.

Pinned versions (override via environment):
  OC_VERSION=${OC_VERSION}
  OC_MIRROR_CHANNEL=${OC_MIRROR_CHANNEL}
  INSTALLER_VERSION=${INSTALLER_VERSION}
EOF
}

main() {
    local check_only=false skip_docker=false skip_register=false

    while (( $# )); do
        case "$1" in
            -c|--check)      check_only=true ;;
            --skip-docker)   skip_docker=true ;;
            --skip-register) skip_register=true ;;
            -h|--help)       usage; exit 0 ;;
            *)               err "Unknown option: $1"; usage >&2; exit 1 ;;
        esac
        shift
    done

    if [[ "${check_only}" == true ]]; then
        verify
        exit $?
    fi

    preflight

    # Register before installing packages: switching RHUI -> RHSM changes the
    # repo set, and dnf should run against the final configuration.
    if [[ "${skip_register}" == true ]]; then
        warn "Skipping subscription registration as requested"
    else
        register_subscription || true
    fi

    install_dnf_packages
    [[ "${skip_docker}" == true ]] && warn "Skipping Docker CE as requested" || install_docker
    install_python_yq
    install_openshift_clients
    check_subscription || true

    echo
    export PATH="${HOME}/.local/bin:${PATH}"
    verify
}

main "$@"
