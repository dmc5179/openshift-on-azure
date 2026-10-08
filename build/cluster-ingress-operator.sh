#!/usr/bin/env bash
#
# Build cluster-ingress-operator.
#
#   Build tool:        podman (via `make release-local`)
#   Release component: cluster-ingress-operator
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="cluster-ingress-operator"
COMPONENT="cluster-ingress-operator"
IMAGE="${PUSH_REGISTRY}/${REPO_NAME}"

main() {
    require_cmd podman skopeo jq git make
    require_build_auth

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    log "Building ${REPO_NAME} -> ${IMAGE}"

    # release-local both builds and pushes. It calls podman itself, so the
    # auth context is passed through REGISTRY_AUTH_FILE rather than a flag.
    ( cd "${dir}" && REGISTRY_AUTH_FILE="${BUILD_AUTH_FILE}" REPO="${IMAGE}" make release-local )

    local tag
    tag=$(discovered_tag podman "${IMAGE}")
    [[ -n "${tag}" ]] || tag=$(short_sha "${dir}")

    record_and_report "${COMPONENT}" "${IMAGE}:${tag}"
}

main "$@"
