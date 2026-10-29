#!/usr/bin/env bash
#
# release-to-imageset.sh — extract every image referenced by an OpenShift
# release and write an oc-mirror imageset-config.yaml that mirrors them all,
# plus the release image itself.
#
set -euo pipefail

# Defaults are relative to the directory you run from, so the usual workflow is
# to cd into a scratch directory holding the oc binary and pull secret for
# that build. An ./oc there wins over the one on PATH, because test builds
# often need a newer client than the installed one.
RELEASE=""
if [[ -x ./oc ]]; then OC_BIN="./oc"; else OC_BIN="oc"; fi
PULL_SECRET="./pull-secret.json"
RELEASE_DIR="./new_release"
OUTPUT="./imageset-config.yaml"
INSECURE=true
SKIP_EXTRACT=false
FORCE=false

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] RELEASE_IMAGE

Runs \`oc adm release new --dir\` against RELEASE_IMAGE, reads the extracted
image-references, and writes an imageset-config.yaml listing every payload
image plus RELEASE_IMAGE itself.

Defaults are relative to the current directory, so run it from a scratch
directory holding the oc binary and pull secret for the build:

  cd ~/scratch/test-build
  $(basename "$0") registry.example.com:5000/openshift/release-images:5.1.0-ec.1-x86_64

Options:
  -r, --release IMAGE     Release image (alternative to the positional arg)
      --oc PATH           oc binary
                          (default: ${OC_BIN})
      --pull-secret PATH  Registry auth file
                          (default: ${PULL_SECRET})
      --dir PATH          Directory oc extracts the release into
                          (default: ${RELEASE_DIR})
  -o, --output PATH       imageset-config.yaml to write
                          (default: ${OUTPUT})
      --secure            Verify TLS (drops --insecure=true from the oc call)
      --skip-extract      Reuse an existing <dir>/image-references instead of
                          running oc again
      --force             Delete a previous extraction in <dir> before running
  -h, --help              Show this help
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -r|--release)   RELEASE="${2:?--release needs a value}"; shift 2 ;;
            --oc)           OC_BIN="${2:?--oc needs a value}"; shift 2 ;;
            --pull-secret)  PULL_SECRET="${2:?--pull-secret needs a value}"; shift 2 ;;
            --dir)          RELEASE_DIR="${2:?--dir needs a value}"; shift 2 ;;
            -o|--output)    OUTPUT="${2:?--output needs a value}"; shift 2 ;;
            --secure)       INSECURE=false; shift ;;
            --skip-extract) SKIP_EXTRACT=true; shift ;;
            --force)        FORCE=true; shift ;;
            -h|--help)      usage; exit 0 ;;
            -*)             usage >&2; die "unknown option: $1" ;;
            *)
                [[ -z "${RELEASE}" ]] || die "release image given twice: '${RELEASE}' and '$1'"
                RELEASE="$1"; shift ;;
        esac
    done
    [[ -n "${RELEASE}" ]] || { usage >&2; die "a release image is required"; }
}

preflight() {
    command -v jq >/dev/null 2>&1 || die "jq is not installed"

    if [[ "${SKIP_EXTRACT}" == false ]]; then
        command -v "${OC_BIN}" >/dev/null 2>&1 || die "oc binary not found or not executable: ${OC_BIN}"
        [[ -f "${PULL_SECRET}" ]] || die "pull secret not found: ${PULL_SECRET}"
        jq -e '.auths' "${PULL_SECRET}" >/dev/null 2>&1 \
            || die "${PULL_SECRET} is not a registry auth file (no .auths object)"
    fi
}

# Only removes a directory that holds a previous extraction or nothing at all,
# so a mistyped --dir cannot take out something unrelated.
clear_release_dir() {
    [[ -d "${RELEASE_DIR}" ]] || return 0
    [[ -n "$(ls -A "${RELEASE_DIR}")" ]] || return 0

    if [[ "${FORCE}" == false ]]; then
        die "${RELEASE_DIR} already has content. Re-run with --force to replace it, or --skip-extract to reuse it."
    fi
    [[ -f "${RELEASE_DIR}/image-references" ]] \
        || die "refusing to delete ${RELEASE_DIR}: it does not look like a previous extraction (no image-references)"

    log "Removing previous extraction in ${RELEASE_DIR}"
    rm -rf "${RELEASE_DIR}"
}

extract_release() {
    clear_release_dir
    mkdir -p "${RELEASE_DIR}"

    log "Extracting ${RELEASE} into ${RELEASE_DIR}"
    "${OC_BIN}" adm release new \
        --insecure="${INSECURE}" \
        --registry-config="${PULL_SECRET}" \
        --from-release "${RELEASE}" \
        --dir "${RELEASE_DIR}"
}

write_imageset() {
    local refs="${RELEASE_DIR}/image-references"
    [[ -f "${refs}" ]] || die "${refs} not found — did the extraction succeed?"

    local count
    count=$(jq '.spec.tags | length' "${refs}") || die "${refs} is not valid JSON"
    (( count > 0 )) || die "${refs} lists no images"

    log "Writing ${OUTPUT}"
    mkdir -p "$(dirname "${OUTPUT}")"
    local tmp="${OUTPUT}.tmp"

    # The release image is not in its own image-references, so it is appended.
    # Each name is emitted as a JSON string, which is also a valid YAML
    # double-quoted scalar — no yq needed, and the Go and Python yq tools
    # disagree on flags anyway.
    {
        printf 'kind: ImageSetConfiguration\n'
        printf 'apiVersion: mirror.openshift.io/v2alpha1\n'
        printf 'mirror:\n'
        printf '  additionalImages:\n'
        jq -r --arg release "${RELEASE}" '
            [.spec.tags[].from.name] + [$release]
            | unique[]
            | "  - name: \(@json)"' "${refs}"
    } > "${tmp}"

    # command mv: interactive shells often alias mv to -i (hangs) or -n
    # (silently refuses to overwrite).
    command mv -f "${tmp}" "${OUTPUT}"

    local written
    written=$(grep -c '^  - name: ' "${OUTPUT}")
    log "Wrote ${written} images (${count} from the payload + the release image)"
    report "${refs}"
}

# Flags references worth a second look before running oc-mirror.
report() {
    local refs="$1" tagged ported

    tagged=$(jq -r --arg release "${RELEASE}" \
        '[.spec.tags[].from.name] + [$release] | unique[] | select(test("@sha256:") | not)' "${refs}")
    if [[ -n "${tagged}" ]]; then
        warn "$(wc -l <<<"${tagged}") image(s) are referenced by tag, not digest. oc-mirror"
        warn "will copy whatever the tag points to when it runs, which may not be"
        warn "what the release was built from:"
        sed 's/^/        /' <<<"${tagged}" >&2
    fi

    ported=$(grep -cE '^  - name: "[^/"]+:[0-9]+/' "${OUTPUT}" || true)
    if (( ported > 0 )); then
        warn "${ported} image(s) are on a registry with an explicit port. If oc-mirror"
        warn "reports \"tag and digest are empty\", those entries are the cause."
    fi
}

main() {
    parse_args "$@"
    preflight

    if [[ "${SKIP_EXTRACT}" == true ]]; then
        log "Skipping extraction; reusing ${RELEASE_DIR}/image-references"
    else
        extract_release
    fi

    write_imageset
    print_mirror_command
}

# oc-mirror needs the same access oc had, passed explicitly: it verifies TLS by
# default and falls back to ~/.docker/config.json for credentials, so without
# these flags every image on the release's own registry fails with no reason
# given.
print_mirror_command() {
    local tls_flag=""
    [[ "${INSECURE}" == true ]] && tls_flag=" \\
  --src-tls-verify=false"

    cat <<EOF

To mirror to disk:

oc-mirror --v2 \\
  --config $(realpath -m "${OUTPUT}") \\
  --authfile $(realpath -m "${PULL_SECRET}")${tls_flag} \\
  file://$(pwd)/mirror
EOF
}

main "$@"
