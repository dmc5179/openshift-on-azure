#!/usr/bin/env bash
#
# Build machine-api-provider-azure.
#
#   Build tool:        podman
#   Release component: azure-machine-controllers
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="machine-api-provider-azure"
COMPONENT="azure-machine-controllers"
IMAGE="${PUSH_REGISTRY}/${REPO_NAME}"
TAG="${TAG:-4.21}"

main() {
    require_cmd podman skopeo jq git
    require_build_auth

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    log "Building ${REPO_NAME} -> ${IMAGE}:${TAG}"
    podman build --authfile "${BUILD_AUTH_FILE}" \
        -t "${IMAGE}:${TAG}" \
        -f Dockerfile.rhel "${dir}"

    log "Pushing ${IMAGE}:${TAG}"
    podman push --authfile "${BUILD_AUTH_FILE}" "${IMAGE}:${TAG}"

    record_and_report "${COMPONENT}" "${IMAGE}:${TAG}"
}

main "$@"
