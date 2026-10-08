#!/usr/bin/env bash
#
# release.sh — assemble the custom OpenShift release and generate an
# imageset-config.yaml for oc-mirror.
#
# Consumes the digests recorded by the scripts in build/ (see
# ${STATE_DIR}/images.json). Run those first.
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

RELEASE_TAG="${RELEASE_TAG:-4.21.custom-$(date +%Y%m%d%H%M)}"
# Pushed through the :443 alias (see RELEASE_AUTH_FILE in lib/common.sh);
# TARGET_RELEASE_READ is the same image addressed normally, for reads and for
# the imageset config.
TARGET_RELEASE="${TARGET_RELEASE:-${RELEASE_PUSH_REGISTRY}/ocp-release:${RELEASE_TAG}}"
TARGET_RELEASE_READ="${TARGET_RELEASE/quay.io:443\//quay.io/}"
IMAGESET_CONFIG="${IMAGESET_CONFIG:-${WORKSPACE}/imageset-config.yaml}"
MIRROR_DIR="${MIRROR_DIR:-${WORKSPACE}/mirror}"

# Release component names that `oc adm release new` overrides. These are the
# keys the build scripts record under.
COMPONENTS=(
    azure-cloud-controller-manager
    azure-machine-controllers
    azure-disk-csi-driver
    cluster-ingress-operator
    cluster-config-operator
)

#=============================================================================
# Release assembly
#=============================================================================

collect_overrides() {
    local missing=() component ref
    OVERRIDES=()

    for component in "${COMPONENTS[@]}"; do
        if ref=$(get_image "${component}"); then
            OVERRIDES+=("${component}=${ref}")
            ok "$(printf '%-32s %s' "${component}" "${ref}")"
        else
            missing+=("${component}")
        fi
    done

    if (( ${#missing[@]} )); then
        err "No recorded image for: ${missing[*]}"
        err "Run the matching script(s) in build/ first."
        return 1
    fi
}

assemble_release() {
    log "Assembling custom release ${TARGET_RELEASE}"
    log "Base: ${BASE_RELEASE}"

    collect_overrides

    # --max-per-registry=1 keeps quay.io from rate-limiting the ~200 blob reads.
    "${OC}" adm release new \
        --max-per-registry=1 \
        --registry-config "${RELEASE_AUTH_FILE}" \
        --from-release "${BASE_RELEASE}" \
        "${OVERRIDES[@]}" \
        --to-image "${TARGET_RELEASE}"

    ok "Release pushed: ${TARGET_RELEASE}"
}

verify_release() {
    log "Verifying custom images landed in the release"

    local component actual
    for component in "${COMPONENTS[@]}"; do
        actual=$("${OC}" adm release info "${TARGET_RELEASE_READ}" \
            --registry-config "${RELEASE_AUTH_FILE}" \
            --image-for="${component}" 2>/dev/null) || {
            err "Could not read ${component} from the release"
            continue
        }
        if [[ "${actual}" == *danclark* ]]; then
            ok "$(printf '%-32s %s' "${component}" "${actual}")"
        else
            err "$(printf '%-32s %s  <- NOT the custom image' "${component}" "${actual}")"
        fi
    done
}

#=============================================================================
# imageset-config.yaml
#=============================================================================

generate_imageset_config() {
    log "Generating ${IMAGESET_CONFIG}"

    # `release info -o json` is a read. Do not use `release new --dir` here:
    # that re-derives the release and verifies it, which fails with "the
    # release could not be reproduced from its inputs" on a release that was
    # itself built with --to-image overrides.
    local refs
    refs=$("${OC}" adm release info "${TARGET_RELEASE_READ}" \
        --registry-config "${RELEASE_AUTH_FILE}" -o json) \
        || die "Could not read ${TARGET_RELEASE_READ}"

    local payload
    payload=$(jq '[.references.spec.tags[].from.name]' <<<"${refs}")
    [[ "$(jq 'length' <<<"${payload}")" -gt 0 ]] \
        || die "No image references found in ${TARGET_RELEASE_READ}"

    # Built in one pass. The previous loop re-serialised the whole file once
    # per image, which is ~195 yq invocations for no benefit.
    jq -n --argjson payload "${payload}" --arg release "${TARGET_RELEASE_READ}" '
        {
          kind: "ImageSetConfiguration",
          apiVersion: "mirror.openshift.io/v2alpha1",
          mirror: {
            additionalImages:
              ([ "registry.redhat.io/ubi8/ubi:latest",
                 "registry.redhat.io/ubi9/ubi:latest" ]
               + $payload + [$release])
              | map({name: .})
          }
        }' | yq -y . > "${IMAGESET_CONFIG}"

    # oc-mirror v2 misreads `registry:port` as part of a tag and fails with
    # "tag and digest are empty". Nothing should reach here with a port, but
    # the failure is opaque enough to be worth catching now.
    local ported
    ported=$(grep -cE '^[[:space:]]*- name: [^/]+:[0-9]+/' "${IMAGESET_CONFIG}" || true)
    (( ported == 0 )) \
        || die "${IMAGESET_CONFIG} has ${ported} reference(s) with a registry port; oc-mirror cannot parse those."

    local count
    count=$(grep -cE '^[[:space:]]*- name:' "${IMAGESET_CONFIG}" || true)
    (( count > 0 )) || die "${IMAGESET_CONFIG} came out empty."
    ok "Wrote ${IMAGESET_CONFIG} (${count} images)"
}

#=============================================================================
# Mirror
#=============================================================================

mirror_to_disk() {
    log "Mirroring to ${MIRROR_DIR} (this takes a while and needs ~150G)"
    mkdir -p "${MIRROR_DIR}"
    REGISTRY_AUTH_FILE="${PULL_AUTH_FILE}" \
        oc-mirror --v2 --config "${IMAGESET_CONFIG}" "file://${MIRROR_DIR}"
    ok "Mirror complete: ${MIRROR_DIR}"
}

#=============================================================================
# Main
#=============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [STAGE]

Assembles the custom OpenShift release from the images recorded by the
scripts in build/, then generates an imageset-config.yaml for oc-mirror.

Stages (default: assemble + verify + imageset):
  --assemble    Run \`oc adm release new\` only
  --verify      Check the custom images are in the release
  --imageset    Generate imageset-config.yaml only
  --mirror      Run oc-mirror to disk (not included by default)
  --all         Everything, including the mirror
  -h, --help    Show this help

Environment:
  RELEASE_TAG=${RELEASE_TAG}
  TARGET_RELEASE=${TARGET_RELEASE}
  (read as ${TARGET_RELEASE_READ})
  BASE_RELEASE=${BASE_RELEASE}
EOF
}

main() {
    require_cmd "${OC}" oc-mirror skopeo jq yq
    require_release_auth
    [[ -f "${IMAGES_JSON}" ]] \
        || die "No build state at ${IMAGES_JSON}. Run the scripts in build/ first."

    case "${1:-}" in
        --assemble) assemble_release ;;
        --verify)   verify_release ;;
        --imageset) generate_imageset_config ;;
        --mirror)   mirror_to_disk ;;
        --all)      assemble_release; verify_release; generate_imageset_config; mirror_to_disk ;;
        -h|--help)  usage ;;
        "")         assemble_release; verify_release; generate_imageset_config
                    echo
                    log "To mirror: $(basename "$0") --mirror" ;;
        *)          err "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
}

main "$@"
