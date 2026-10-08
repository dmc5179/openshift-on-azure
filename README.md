# OpenShift on Azure — Custom Release Build

Automation for building a custom OpenShift 4.21 release that can be deployed
into **Azure Gov Secret (DoD IL6)** and **Azure Gov Top Secret (DoD IL7)**
regions.

Stock OpenShift cannot deploy into these regions: several components resolve
Azure endpoints from a hardcoded cloud-name table that has no entry for the
sovereign clouds. This repo builds patched forks of the affected components,
replaces them inside an official OpenShift release payload, and mirrors the
result for a disconnected install.

## Why these components

| Component | What the patch does |
|---|---|
| `cloud-provider-azure` | Falls back to the first ARM metadata entry when no entry matches the configured cloud name |
| `cluster-ingress-operator` | Keys Azure DNS behaviour off `ARMEndpoint != ""` rather than `== "AzureStackCloud"` |
| `machine-api-provider-azure` | Uses `EnvironmentFromURL` whenever `armEndpoint` is set, not only for Stack Hub |
| `azure-disk-csi-driver` | Carries the same ARM metadata fallback |
| `cluster-config-operator` | Drops the cloud-name validation allowlist |
| `installer` | Resolves the Azure environment from a file / encoded env var and passes it to CAPZ |

Upstream tracking: **OCPSTRAT-1672** (IL6) and **OCPSTRAT-3793** (IL7), with
installer work under epic **CORS-4471**. Red Hat engineering is targeting
roughly the OpenShift 5.1 timeframe, so this build runs well ahead of official
support.

## Repository layout

```
prereq.sh                 Install build dependencies on a RHEL 9 host
setup-auth.sh             Build the registry auth files from your credentials
release.sh                Assemble the custom release + imageset-config.yaml
lib/common.sh             Shared config, logging, and build state
build/                    One script per component
docs/
  building-operators.md   How each component is built
  custom-release.md       How the release payload is assembled
  mirroring.md            How the content is mirrored with oc-mirror
```

## Requirements

- A **RHEL 9 x86_64** host. RHEL specifically — the `azure-disk-csi-driver`
  build runs `dnf install` inside the container and needs entitlement
  certificates from the host.
- Registered with `subscription-manager`. On an AWS RHEL AMI, RHUI
  certificates do not work inside a container build; `prereq.sh` will offer to
  register the host for you.
- Roughly **250 GB** of free disk: the installer build tree is large and the
  mirror step alone is around 150 GB.
- A Red Hat pull secret, a quay.io account you can push to, and a
  `registry.ci.openshift.org` token.

## Quick start

```bash
# 1. Install dependencies (prompts to register with RHN if needed)
./prereq.sh

# 2. Set up registry auth — see "Registry authentication" below
./setup-auth.sh --pull-secret ~/pull-secret.json --quay-auth ~/quay-auth.json

# 3. Build each component (independent; run in any order)
./build/cluster-ingress-operator.sh
./build/cloud-provider-azure.sh
./build/machine-api-provider-azure.sh
./build/azure-disk-csi-driver.sh
./build/cluster-config-operator.sh
./build/installer.sh

# 4. Assemble the release and generate imageset-config.yaml
./release.sh

# 5. Mirror the content to disk
./release.sh --mirror
```

Each build script records the image it produced in
`~/workspace/.release-state/images.json`. `release.sh` reads that file, so
builds can be re-run individually without redoing the others.

## Registry authentication

You supply two credentials; `setup-auth.sh` derives everything else.

```bash
./setup-auth.sh \
  --pull-secret ~/pull-secret.json \
  --quay-auth   ~/quay-auth.json
```

| You supply | What it is |
|---|---|
| `--pull-secret` | OpenShift pull secret from console.redhat.com. **Must include a `registry.ci.openshift.org` entry** — see below. |
| `--quay-auth` | A quay.io credential with push access to your namespace. |

### Why three generated files

Your custom images are in public quay repos, so pulling them back needs no
credential at all. But two steps each need to touch two registries at once,
and a registry auth file holds only one credential per host:

| File | Contents | Used by | Why |
|---|---|---|---|
| `~/.docker/config.json` | pull secret, unmodified | `oc-mirror` | Reads the `ocp-v4.0-art-dev` payload images, which are **not** anonymously readable |
| `~/.docker-build/config.json` | pull secret with `quay.io` replaced by your token | all build scripts | A build pulls base images from `registry.ci.openshift.org` and pushes to `quay.io` in one invocation. No build reads from quay.io, so overwriting that entry is free |
| `~/.docker/release-auth.json` | pull secret plus your token under `quay.io:443` | `release.sh` only | `oc adm release new` must read the payload from quay.io *and* push the result to quay.io through a single `--registry-config` |

That last row is the only place the `:443` trick survives. Auth matching is a
literal string comparison, so `quay.io:443` acts as a second entry for the same
host: reads match `quay.io` and use the pull secret, while the push target is
addressed as `quay.io:443` and uses your token. Nothing else in the pipeline
needs it — build scripts, digest lookups, and the imageset config all use plain
`quay.io`.

### The CI token expires

`registry.ci.openshift.org` credentials are short-lived OAuth tokens, and a
pull secret saved more than a day or so ago will almost certainly have a dead
one. Every container build pulls its base image from there, so this is the
most common reason a build fails immediately.

Refresh it by logging in at
[the CI console](https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com),
copying the login command, and then:

```bash
podman login --authfile ~/pull-secret.json registry.ci.openshift.org \
  -u unused -p <token>
./setup-auth.sh --pull-secret ~/pull-secret.json --quay-auth ~/quay-auth.json
```

Symptom of an expired token:

```
unable to retrieve auth token: invalid username/password: authentication required
```

Note that is distinct from a *missing* entry, which reports
`authentication required` with no mention of the username.

## Configuration

Every script reads its settings from `lib/common.sh`, and each is overridable
by environment variable:

| Variable | Default | Meaning |
|---|---|---|
| `WORKSPACE` | `~/workspace` | Where repos are cloned and output is written |
| `GITHUB_ORG` | `dmc5179` | Fork owner |
| `GIT_BRANCH` | `azure-il6-release-4.21` | Branch to build |
| `QUAY_NAMESPACE` | `danclark` | Your quay.io namespace |
| `PUSH_REGISTRY` | `quay.io/danclark` | Push target for every component build |
| `BASE_RELEASE` | `quay.io/openshift-release-dev/ocp-release:4.21.1-x86_64` | Release payload to patch |
| `PULL_AUTH_FILE` | `~/.docker/config.json` | Pull secret, unmodified |
| `BUILD_AUTH_DIR` | `~/.docker-build` | Auth context for builds |
| `RELEASE_AUTH_FILE` | `~/.docker/release-auth.json` | Auth for release assembly |
| `RELEASE_PUSH_REGISTRY` | `quay.io:443/danclark` | Release push target (`:443` alias) |
| `OC` | `oc-4.21.5` | `oc` binary to use |

## Status

Validated end-to-end on a RHEL 9.8 host:

Run end-to-end on a RHEL 9.8 host, producing a real custom release:

| Script | State |
|---|---|
| `prereq.sh` | Clean host to fully provisioned; idempotent |
| `setup-auth.sh` | All three contexts; credential swap verified by fingerprint |
| `build/` (all six) | All build, push, and record their digests |
| `release.sh --assemble` | Pushed `ocp-release:4.21.custom-202610080230` |
| `release.sh --verify` | All five overrides confirmed in the payload |
| `release.sh --imageset` | 195 entries, validated as YAML |
| `release.sh --mirror` | **Not yet exercised** |

### Known gaps

- **`azure-cloud-node-manager` is shipped stock.** It is a release component
  and is not overridden. It may need the same `pkg/azclient` patch as the
  controller manager — see
  [building the operators](docs/building-operators.md#cloud-provider-azure).
- **Mirroring is unexercised.** Everything up to and including
  `imageset-config.yaml` has been run for real.
- **The RHCOS VHD upload is manual** — upload the VHD to a storage account,
  generate a SAS URL, and set `platform.azure.clusterOSImage`.

## Further reading

- [Building the operators](docs/building-operators.md)
- [Building the custom release](docs/custom-release.md)
- [Mirroring with oc-mirror](docs/mirroring.md)
