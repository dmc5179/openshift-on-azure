# Mirroring with oc-mirror

IL6 and IL7 regions are disconnected, so every image the cluster needs has to
be mirrored out of quay.io and carried in. `oc-mirror` does this in two hops:
registry to disk, then disk to the destination registry inside the enclave.

This document covers the first hop and the `imageset-config.yaml` that drives
it.

## Prerequisites

- The custom release built and pushed
  ([building the custom release](custom-release.md))
- `oc-mirror` 4.22.4 or newer — the v2 workflow is required
- **python-yq**, not the Go yq (see below)
- Roughly 150 GB of free disk

### The two yq problem

Two unrelated tools are called `yq`. Generating the imageset config uses
`yq -Y --arg`, which is **python-yq** (`kislyuk/yq`), a jq wrapper. The Go yq
(`mikefarah/yq`) accepts neither flag and will silently produce a broken
config.

```bash
pip3 install --user yq

# Verify by behaviour, not version string:
echo '{"a":1}' | yq -Y --arg k v '.b = $k'
```

If that errors, you have the wrong yq. `prereq.sh` installs and checks the
right one.

## Generating imageset-config.yaml

### With the script

```bash
./release.sh --imageset
```

### By hand

Read the image list off the release and write the config in one pass:

```bash
cd ~/workspace
REL=quay.io/danclark/ocp-release:<tag>

oc-4.21.5 adm release info "$REL" \
  --registry-config ~/.docker/release-auth.json -o json \
| jq '[.references.spec.tags[].from.name]' \
| jq -n --argjson payload "$(cat)" --arg release "$REL" '
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
    }' \
| yq -y . > imageset-config.yaml
```

Two things that are easy to get wrong here:

**Use `release info -o json`, not `release new --dir`.** The latter re-derives
the release and verifies it, which fails on a release that was itself built
with `--to-image` overrides:

```
error: the release could not be reproduced from its inputs
```

`release info` is a plain read and has no such problem.

**Use `yq -y`, not `yq -Y`.** In python-yq, `-Y` is *roundtrip* mode, intended
for YAML input where formatting should be preserved. Given JSON input it emits
flow style — valid YAML, but collapsed onto single lines and awkward to edit:

```yaml
# yq -Y  (flow style)
mirror: {additionalImages: [{name: "a/b:1"}, {name: "c/d:2"}]}

# yq -y  (block style)
mirror:
  additionalImages:
    - name: a/b:1
    - name: c/d:2
```

The older approach of appending one image at a time with
`yq -Y --arg img ... '.mirror.additionalImages += [...]'` also works, since
there the input really is YAML — but it re-serialises the whole file once per
image, roughly 195 times. If you do write a loop like that, use
`command mv -f` for the temp-file swap: interactive shells often alias `mv` to
`mv -i` (which hangs waiting for a prompt) or `mv -n` (which refuses to
overwrite and silently discards every update while still exiting zero).

The finished file has 195 entries: 2 UBI base images, 192 payload images, and
the release image.

## Keep registry references plain

**oc-mirror v2 cannot parse `registry:port/repo@sha256:...`.** It reads the
port as part of a tag and fails with:

```
tag and digest are empty
```

Nothing in a generated `imageset-config.yaml` should carry a port. Component
builds push to plain `quay.io`, and `release.sh` strips the `:443` alias from
the release reference before writing it out, so this resolves itself — but if
you hand-edit the file, do not reintroduce a `:443` reference:

```yaml
# Wrong — oc-mirror cannot parse this
- name: quay.io:443/danclark/cluster-ingress-operator@sha256:1cff962a...

# Right
- name: quay.io/danclark/cluster-ingress-operator@sha256:1cff962a...
```

The `:443` alias exists only so that release assembly can hold two quay.io
credentials at once; mirroring only reads, so it never needs it.

## Mirroring to disk

Mirroring reads the Red Hat payload images, so it needs the **unmodified**
pull secret — not the build auth context, whose `quay.io` entry is your push
token.

```bash
mkdir -p ~/workspace/mirror
REGISTRY_AUTH_FILE=~/.docker/config.json \
  oc-mirror --v2 \
  --config ./imageset-config.yaml \
  file://${PWD}/mirror
```

Expect this to run for a long while and produce roughly 150 GB. Progress and
errors go to a log in the working directory — check it rather than relying on
the terminal output.

With the script:

```bash
./release.sh --mirror
```

## Mirroring into the enclave

Once the disk content is transferred inside, the second hop pushes to the
destination registry:

```bash
oc-mirror --v2 \
  --config ./imageset-config.yaml \
  --from file://<path-to-mirror> \
  docker://<destination-registry>
```

`oc-mirror` emits `IDMS`/`ITMS` manifests and a `CatalogSource` under its
`working-dir`. Those have to be applied to the cluster so it resolves images
from the mirror rather than quay.io.

## Mirroring a release someone else built

Engineering test builds arrive as a finished release image on their own
registry rather than something this repo assembled. `release-to-imageset.sh`
covers that case. Run it from a scratch directory holding the oc binary and
pull secret for the build:

```bash
cd ~/scratch/test-build        # contains ./oc and ./pull-secret.json
/path/to/release-to-imageset.sh <registry>:<port>/openshift/release-images:<tag>
```

It runs `oc adm release new --dir ./new_release`, reads
`new_release/image-references`, and writes `./imageset-config.yaml` listing
every payload image plus the release image itself. The release image is not in
its own `image-references`, so it has to be added separately, and the script
does that.

Options worth knowing about:

- `--skip-extract` reuses an existing `new_release/image-references`, so you
  can regenerate the config without repeating the extraction.
- `--force` replaces a previous extraction. It only deletes a directory that
  contains an `image-references` file.
- `--oc`, `--pull-secret`, `--dir` and `-o` override the defaults.

### Give oc-mirror the same access oc had

These registries are typically HTTPS with a certificate from a private CA, and
they require a login whose credentials exist only in the pull secret you were
given. `oc adm release new` gets past both with `--insecure=true` and
`--registry-config`. **oc-mirror needs the equivalents passed explicitly**,
otherwise every image on that registry fails, including the release image:

```bash
oc-mirror --v2 \
  --config ./imageset-config.yaml \
  --authfile ./pull-secret.json \
  --src-tls-verify=false \
  file://${PWD}/mirror
```

Without them oc-mirror verifies TLS by default and falls back to
`~/.docker/config.json` for credentials. The main log reports only
`Failed to copy generic <image>` with no reason. To see which problem it is,
test one image directly:

```bash
skopeo inspect --tls-verify=false --authfile ./pull-secret.json \
  docker://<registry>:<port>/<repo>:<tag>
```

| skopeo error | Fix |
|---|---|
| `x509: certificate signed by unknown authority` | `--src-tls-verify=false`, or install the CA as `/etc/containers/certs.d/<registry>:<port>/ca.crt` |
| `authentication required` | `--authfile` pointing at the pull secret that has the registry's entry |

Installing the CA is the better long-term fix, because certificates are then
still verified.

### Images pinned by tag

Custom components in a test build are often referenced by a tag such as
`:latest` rather than a digest, and the script warns when it sees them.
oc-mirror copies whatever the tag points to when it runs, so if the builder
pushes again between handing you the release and your mirror run, the mirror
won't match the release. Mirror promptly, or ask for digest references.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `tag and digest are empty` | A `registry:port` + `@sha256:` reference — strip `:443`, use a tag |
| `yq: unknown option -Y` | Go yq instead of python-yq |
| imageset config silently missing entries | `mv` aliased to `mv -n`; use `command mv -f` |
| `manifest unknown` | A digest read from `podman inspect` instead of `skopeo inspect` |
| `unauthorized` on `ocp-v4.0-art-dev` | Using the build auth context; payload images need the unmodified pull secret |
| quay.io rate limiting | Add `--max-per-registry=1` to `oc adm` commands |
| `Failed to copy generic` for every image on one registry, with no reason given | TLS or auth to that registry: pass `--src-tls-verify=false` and `--authfile`. See [mirroring a release someone else built](#mirroring-a-release-someone-else-built) |
