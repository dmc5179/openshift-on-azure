# Building the Custom Release

An OpenShift release is a container image whose payload lists every component
image by digest. `oc adm release new` can take an existing release and
substitute individual components, producing a new release image that is
identical to the original except for the components you replaced.

That is what this step does: take the official 4.21.1 release, swap in the
five patched Azure components, and push the result.

## Prerequisites

- All five container components built and pushed
  ([building the operators](building-operators.md))
- `~/.docker/release-auth.json`, produced by `./setup-auth.sh`
- `oc` 4.21.5

## With the script

```bash
./release.sh
```

That runs three stages: assemble, verify, and generate the
`imageset-config.yaml`. Individual stages:

```bash
./release.sh --assemble   # oc adm release new only
./release.sh --verify     # confirm the custom images are in the release
./release.sh --imageset   # generate imageset-config.yaml only
./release.sh --mirror     # run oc-mirror (not included by default)
./release.sh --all        # everything, including the mirror
```

`release.sh` reads the digests recorded by the build scripts from
`~/workspace/.release-state/images.json`. If a component is missing it names
it and stops, rather than silently producing a release that still points at
the stock image.

Override the output tag with `RELEASE_TAG`, or the whole target with
`TARGET_RELEASE`:

```bash
RELEASE_TAG=4.21.il6-test ./release.sh
```

## By hand

```bash
oc-4.21.5 adm release new \
  --max-per-registry=1 \
  --registry-config ~/.docker/release-auth.json \
  --from-release quay.io/openshift-release-dev/ocp-release:4.21.1-x86_64 \
  azure-cloud-controller-manager=quay.io/danclark/azure-cloud-controller-manager@sha256:<digest> \
  azure-machine-controllers=quay.io/danclark/machine-api-provider-azure@sha256:<digest> \
  azure-disk-csi-driver=quay.io/danclark/azuredisk-csi@sha256:<digest> \
  cluster-ingress-operator=quay.io/danclark/cluster-ingress-operator@sha256:<digest> \
  cluster-config-operator=quay.io/danclark/cluster-config-operator@sha256:<digest> \
  --to-image quay.io:443/danclark/ocp-release:4.21.custom-$(date +%Y%m%d%H%M)
```

### Why this command needs the `:443` alias

This is the only step in the pipeline that reads from quay.io **and** pushes to
quay.io, and `oc adm release new` takes a single `--registry-config`. The
payload images under `quay.io/openshift-release-dev/ocp-v4.0-art-dev` are not
anonymously readable, so the Red Hat credential has to stay on `quay.io`; your
push token is filed under `quay.io:443` and the `--to-image` target is
addressed that way. `setup-auth.sh` builds that merged file.

Everywhere else — component builds, digest lookups, the imageset config —
uses plain `quay.io`.

Three more things to get right:

**Component names, not repo names.** The key on the left of each `=` is the
OpenShift component name. `cloud-provider-azure` is
`azure-cloud-controller-manager`; `machine-api-provider-azure` is
`azure-machine-controllers`. Getting one wrong adds a new tag to the payload
instead of replacing the existing one, and the build silently succeeds.

**Digests, not tags.** Use `image@sha256:...`, and get the digest from
`skopeo inspect docker://...`, not from `podman inspect`. A local digest that
differs from the registry's produces `manifest unknown`.

**`--max-per-registry=1`.** The command reads roughly 200 images from quay.io.
Without this it opens many parallel connections and gets rate-limited.

## Verifying

Confirm each override actually landed:

```bash
for c in azure-cloud-controller-manager azure-machine-controllers \
         azure-disk-csi-driver cluster-ingress-operator cluster-config-operator; do
  printf '%-32s ' "$c"
  oc-4.21.5 adm release info quay.io/danclark/ocp-release:<tag> \
    --registry-config ~/.docker/release-auth.json --image-for="$c"
done
```

Every line should point at your namespace. Any that still points at
`quay.io/openshift-release-dev` was not overridden — most likely a misspelled
component name.

`./release.sh --verify` does this and flags anything that is not a custom
image.

## Do not re-derive the release

Once built, read the release with `oc adm release info`. Running
`oc adm release new --from-release <your-release> --dir ...` against it fails:

```
error: the release could not be reproduced from its inputs
```

`release new` re-derives the payload and checks the result matches, and a
release assembled with `--to-image` overrides does not reproduce. This matters
because generating the imageset config needs the payload image list — see
[mirroring](mirroring.md).

## A worked example

From the original build on 2026-09-08:

```
Release:  quay.io/danclark/ocp-release:4.21.custom-202609081534
Digest:   sha256:83203d90a185238b6e863bcb4f9800e056922887f5074ce1f951c417a072dbef
Base:     quay.io/openshift-release-dev/ocp-release:4.21.1-x86_64
Payload:  192 component images, 5 of them custom
```

## Next

[Mirroring with oc-mirror](mirroring.md)
