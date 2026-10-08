#!/usr/bin/env bash
#
# Build the OpenShift installer.
#
#   Build tool:        go (./hack/build.sh)
#   Release component: none — this produces a binary, not a container image,
#                      so it is not part of `oc adm release new`. It is shipped
#                      alongside the release and used to deploy it.
#
# Takes roughly 30 minutes: hack/build.sh compiles a sub-binary per cloud
# provider.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO_NAME="installer"

main() {
    require_cmd go git

    clone_or_update "${REPO_NAME}"
    local dir="${WORKSPACE}/${REPO_NAME}"

    log "Building ${REPO_NAME} (expect ~30 minutes)"
    ( cd "${dir}" && ./hack/build.sh )

    local bin="${dir}/bin/openshift-install"
    [[ -x "${bin}" ]] || die "Build finished but ${bin} is missing."

    init_state
    local tmp="${IMAGES_JSON}.tmp"
    jq --arg v "${bin}" '.["_installer_binary"] = $v' "${IMAGES_JSON}" > "${tmp}"
    replace_file "${tmp}" "${IMAGES_JSON}"

    ok "Installer binary: ${bin} ($(du -h "${bin}" | cut -f1))"
}

main "$@"
