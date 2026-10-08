#!/usr/bin/env bash
#
# Build cloud-provider-azure (Azure cloud controller manager).
#
#   Build tool:        docker buildx
#   Release component: azure-cloud-controller-manager
#
# The fork branch already points the Makefile at
# openshift-hack/images/cloud-controller-manager-openshift.Dockerfile, so no
# local edit is needed — this builds from a clean checkout.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="cloud-provider-azure"
COMPONENT="azure-cloud-controller-manager"
IMAGE="${PUSH_REGISTRY}/azure-cloud-controller-manager"

main() {
    require_cmd docker skopeo jq git make
    require_build_auth

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    log "Building ${REPO_NAME} -> ${IMAGE}"

    # The Makefile calls docker itself; DOCKER_CONFIG points it at the build
    # auth context so base-image pulls resolve.
    ( cd "${dir}" && DOCKER_CONFIG="${BUILD_AUTH_DIR}" \
        ARCH=amd64 IMAGE_REGISTRY="${PUSH_REGISTRY}" make build-ccm-image )

    # The Makefile truncates the SHA to 7 characters; git's --short can return
    # more. Take the tag from the image that was just built.
    local tag
    tag=$(discovered_tag docker "${IMAGE}")
    [[ -n "${tag}" ]] || die "Build finished but no ${IMAGE} image is present."

    log "Pushing ${IMAGE}:${tag}"
    docker --config "${BUILD_AUTH_DIR}" push "${IMAGE}:${tag}"

    record_and_report "${COMPONENT}" "${PUSH_REGISTRY}/azure-cloud-controller-manager:${tag}"

    # Open question: azure-cloud-node-manager is a release component and is
    # NOT overridden, so the release ships the stock one. It imports
    # pkg/provider just as the controller manager does, so it may well reach
    # the patched pkg/azclient cloud-config path — static inspection was not
    # conclusive. The Makefile has a build-node-image target using
    # openshift-hack/images/cloud-node-manager-openshift.Dockerfile if it
    # turns out to be needed.
}

main "$@"
