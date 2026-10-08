#!/usr/bin/env bash
#
# setup-auth.sh — build the registry auth files the pipeline needs from the
# two credentials you supply.
#
# Inputs (you provide):
#   --pull-secret FILE   OpenShift pull secret. Must include
#                        registry.ci.openshift.org for the container builds.
#   --quay-auth FILE     quay.io token with push access to your namespace.
#
# Outputs:
#   ~/.docker/config.json         pull secret, unmodified  — oc-mirror
#   ~/.docker-build/config.json   CI pull + quay push      — all builds
#   ~/.docker/release-auth.json   quay.io + quay.io:443    — release assembly
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PULL_SECRET_SRC=""
QUAY_AUTH_SRC=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --pull-secret FILE --quay-auth FILE

Builds the registry auth files used by the build and release scripts.

  --pull-secret FILE   OpenShift pull secret (from console.redhat.com).
                       Must contain a registry.ci.openshift.org entry.
  --quay-auth FILE     quay.io credentials with push access to
                       ${QUAY_NAMESPACE}.
  -h, --help           Show this help.

Writes:
  ${PULL_AUTH_FILE}
  ${BUILD_AUTH_FILE}
  ${RELEASE_AUTH_FILE}
EOF
}

validate_json() {
    local f="$1" label="$2"
    [[ -f "${f}" ]] || die "${label}: ${f} does not exist"
    jq -e '.auths' "${f}" >/dev/null 2>&1 \
        || die "${label}: ${f} is not a valid registry auth file (no .auths object)"
}

install_pull_secret() {
    log "Installing pull secret -> ${PULL_AUTH_FILE}"
    mkdir -p "$(dirname "${PULL_AUTH_FILE}")"
    install -m 0600 "${PULL_SECRET_SRC}" "${PULL_AUTH_FILE}"

    local reg
    for reg in quay.io registry.redhat.io registry.ci.openshift.org; do
        if has_registry "${PULL_AUTH_FILE}" "${reg}"; then
            ok "  ${reg}"
        elif [[ "${reg}" == registry.ci.openshift.org ]]; then
            # Fatal: every container build pulls its base image from here.
            err "  ${reg} MISSING — container builds cannot pull base images."
            err "  Token: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com"
            err "  podman login --authfile ${PULL_AUTH_FILE} ${reg} -u unused -p <token>"
            return 1
        else
            warn "  ${reg} missing"
        fi
    done
}

install_build_auth() {
    log "Building build auth -> ${BUILD_AUTH_FILE}"
    has_registry "${QUAY_AUTH_SRC}" "quay.io" \
        || die "${QUAY_AUTH_SRC} has no quay.io entry"

    mkdir -p "${BUILD_AUTH_DIR}"
    chmod 0700 "${BUILD_AUTH_DIR}"

    # Pull secret with quay.io swapped for the push token: a component build
    # pulls base images from registry.ci.openshift.org and pushes to quay.io in
    # a single invocation. No build reads from quay.io, so losing the Red Hat
    # entry here costs nothing.
    jq -s '.[0] as $pull | .[1] as $push
           | $pull
           | .auths["quay.io"] = $push.auths["quay.io"]' \
        "${PULL_AUTH_FILE}" "${QUAY_AUTH_SRC}" > "${BUILD_AUTH_FILE}"
    chmod 0600 "${BUILD_AUTH_FILE}"
    ok "  registry.ci.openshift.org (pull) + quay.io (push)"
}

install_release_auth() {
    log "Building release auth -> ${RELEASE_AUTH_FILE}"

    # Release assembly reads the payload from quay.io and pushes the result to
    # quay.io in one command with a single --registry-config. Auth matching is
    # a literal string compare, so the push credential is filed under
    # `quay.io:443` and addressed that way in --to-image; reads continue to
    # match `quay.io` and use the pull secret.
    jq -s '.[0] as $pull | .[1] as $push
           | $pull
           | .auths["quay.io:443"] = $push.auths["quay.io"]' \
        "${PULL_AUTH_FILE}" "${QUAY_AUTH_SRC}" > "${RELEASE_AUTH_FILE}"
    chmod 0600 "${RELEASE_AUTH_FILE}"

    has_registry "${RELEASE_AUTH_FILE}" "quay.io" || die "release auth lost its quay.io entry"
    has_registry "${RELEASE_AUTH_FILE}" "quay.io:443" || die "release auth has no quay.io:443 entry"
    ok "  quay.io (read payload) + quay.io:443 (push release)"
}

verify() {
    log "Verifying"
    local f
    for f in "${PULL_AUTH_FILE}" "${BUILD_AUTH_FILE}" "${RELEASE_AUTH_FILE}"; do
        printf '  %-44s %s\n' "${f}" "$(jq -r '.auths | keys | join(", ")' "${f}")"
    done

    # The push credential must actually be able to write. A read-only token
    # here fails at the end of a long build instead of now.
    log "Checking the push credential can reach quay.io"
    if skopeo inspect --authfile "${BUILD_AUTH_FILE}" \
            docker://quay.io/"${QUAY_NAMESPACE}"/cluster-ingress-operator:does-not-exist 2>&1 \
            | grep -qi 'unauthor\|authentication'; then
        warn "quay.io rejected the push credential — check the token"
    else
        ok "Push credential accepted by quay.io"
    fi
}

main() {
    while (( $# )); do
        case "$1" in
            --pull-secret) PULL_SECRET_SRC="${2:-}"; shift 2 ;;
            --quay-auth)   QUAY_AUTH_SRC="${2:-}";   shift 2 ;;
            -h|--help)     usage; exit 0 ;;
            *)             err "Unknown option: $1"; usage >&2; exit 1 ;;
        esac
    done

    [[ -n "${PULL_SECRET_SRC}" && -n "${QUAY_AUTH_SRC}" ]] || { usage >&2; exit 1; }

    require_cmd jq skopeo
    validate_json "${PULL_SECRET_SRC}" "pull secret"
    validate_json "${QUAY_AUTH_SRC}" "quay auth"

    install_pull_secret
    install_build_auth
    install_release_auth
    echo
    verify
    echo
    log "Auth setup complete."
}

main "$@"
