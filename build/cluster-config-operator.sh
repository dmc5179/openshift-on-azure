#!/usr/bin/env bash
#
# Build cluster-config-operator.
#
#   Build tool:        podman
#   Release component: cluster-config-operator
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="cluster-config-operator"
COMPONENT="cluster-config-operator"
IMAGE="${PUSH_REGISTRY}/${REPO_NAME}"
TAG="${TAG:-latest}"

main() {
    require_cmd podman skopeo jq git
    require_build_auth

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    log "Building ${REPO_NAME} -> ${IMAGE}:${TAG}"

    # The repo's `make image-ocp-cluster-config-operator` target needs
    # imagebuilder; building the Dockerfile directly avoids that dependency.
    podman build --authfile "${BUILD_AUTH_FILE}" \
        -t "${IMAGE}:${TAG}" \
        -f Dockerfile.rhel7 "${dir}"

    log "Pushing ${IMAGE}:${TAG}"
    podman push --authfile "${BUILD_AUTH_FILE}" "${IMAGE}:${TAG}"

    record_and_report "${COMPONENT}" "${IMAGE}:${TAG}"
}

main "$@"
