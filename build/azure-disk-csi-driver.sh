#!/usr/bin/env bash
#
# Build azure-disk-csi-driver.
#
#   Build tool:        docker buildx
#   Release component: azure-disk-csi-driver
#
# This is the only component whose build runs `dnf install` inside the
# container, so it needs RHEL entitlement certificates bind-mounted from the
# host. The host must be registered with subscription-manager (prereq.sh can
# do this) — RHUI certs do not work inside the build.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="azure-disk-csi-driver"
COMPONENT="azure-disk-csi-driver"
IMAGE="${PUSH_REGISTRY}/azuredisk-csi"

# Fallback only. The tag is normally read off the built image; the Makefile
# composes it as ${IMAGE_VERSION}-linux-${ARCH}, so pinning it here would go
# stale on the next version bump.
CSI_TAG_FALLBACK="${CSI_TAG:-v1.34.2-linux-amd64}"

# Entitlement certs are named per-host, and the Makefile and Dockerfile
# reference them literally. Rewrite both to match this host's cert.
patch_entitlement_paths() {
    local dir="$1" cert_base="$2"

    log "Pointing build files at entitlement cert ${cert_base}.pem"
    local f
    for f in Makefile Dockerfile.openshift.rhel7; do
        [[ -f "${dir}/${f}" ]] || { warn "${f} not found in ${REPO_NAME}"; continue; }
        sed -i \
            -e "s|/etc/pki/entitlement/[0-9]\+-key\.pem|/etc/pki/entitlement/${cert_base}-key.pem|g" \
            -e "s|/etc/pki/entitlement/[0-9]\+\.pem|/etc/pki/entitlement/${cert_base}.pem|g" \
            "${dir}/${f}"
        ok "Patched ${f}"
    done
}

main() {
    require_cmd docker skopeo jq git make
    require_build_auth

    local cert_base
    cert_base=$(sudo find /etc/pki/entitlement -name '*.pem' ! -name '*-key.pem' 2>/dev/null | head -1 || true)
    [[ -n "${cert_base}" ]] \
        || die "No RHEL entitlement cert found. Register the host: ./prereq.sh"
    cert_base=$(basename "${cert_base}" .pem)

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    patch_entitlement_paths "${dir}" "${cert_base}"

    log "Building ${REPO_NAME} -> ${IMAGE}"

    # The Makefile defaults to OUTPUT_TYPE=registry, which pushes during the
    # build and fails on the quay.io auth split. Build to the local docker
    # daemon instead and push separately with the push-specific config.
    ( cd "${dir}" && DOCKER_CONFIG="${BUILD_AUTH_DIR}" \
        REGISTRY="${PUSH_REGISTRY}" OUTPUT_TYPE=docker make container-linux )

    local tag
    tag=$(discovered_tag docker "${IMAGE}")
    [[ -n "${tag}" ]] || tag="${CSI_TAG_FALLBACK}"

    log "Pushing ${IMAGE}:${tag}"
    docker --config "${BUILD_AUTH_DIR}" push "${IMAGE}:${tag}"

    record_and_report "${COMPONENT}" "${IMAGE}:${tag}"
}

main "$@"
