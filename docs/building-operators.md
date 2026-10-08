# Building the Operators

Six repositories are built. Five produce container images that replace
components inside the OpenShift release payload; the sixth produces the
installer binary, which ships alongside the release rather than inside it.

All forks live under `github.com/dmc5179` on branch `azure-il6-release-4.21`.

| Repo | Release component name | Build tool | Script |
|---|---|---|---|
| `cluster-ingress-operator` | `cluster-ingress-operator` | podman | `build/cluster-ingress-operator.sh` |
| `cloud-provider-azure` | `azure-cloud-controller-manager` | docker buildx | `build/cloud-provider-azure.sh` |
| `machine-api-provider-azure` | `azure-machine-controllers` | podman | `build/machine-api-provider-azure.sh` |
| `azure-disk-csi-driver` | `azure-disk-csi-driver` | docker buildx | `build/azure-disk-csi-driver.sh` |
| `cluster-config-operator` | `cluster-config-operator` | podman | `build/cluster-config-operator.sh` |
| `installer` | *(binary, not a release component)* | go | `build/installer.sh` |

The "release component name" column matters: those are the keys
`oc adm release new` expects, and they do not always match the repo name.
`cloud-provider-azure` becomes `azure-cloud-controller-manager`, and
`machine-api-provider-azure` becomes `azure-machine-controllers`.

## Before you start

Run `./setup-auth.sh` first — see
[registry authentication](../README.md#registry-authentication).

Every component build uses a single auth context,
`~/.docker-build/config.json`: it pulls base images from
`registry.ci.openshift.org` and pushes to `quay.io/<namespace>`, and some
Makefile targets do both inside one invocation. The scripts check it up front
rather than cloning the repo and failing later on an opaque
`authentication required`.

The `quay.io:443` alias is **not** used here — that is only needed for release
assembly. Builds never read from quay.io, so a single plain `quay.io` entry
holding your push token is sufficient.

> **Most common failure:** `registry.ci.openshift.org` tokens are short-lived.
> `invalid username/password: authentication required` on the first `FROM`
> means the token expired; refresh it and re-run `setup-auth.sh`.

## The digest rule

After pushing, always read the digest back **from the registry**, never from
the local image store:

```bash
skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/<image>:<tag> | jq -r .Digest
```

`podman inspect --format '{{.Digest}}'` returns the *local* manifest digest,
which can differ from what the registry stored. Feeding a local digest to
`oc adm release new` produces a `manifest unknown` failure that is slow to
diagnose. The scripts handle this through `remote_digest()` in
`lib/common.sh`.

---

## cluster-ingress-operator

The Makefile's `release-local` target builds *and* pushes in one go. It calls
podman itself, so the auth context is passed through `REGISTRY_AUTH_FILE`
rather than a flag — this is the case the single build auth context exists
for.

```bash
cd ~/workspace/cluster-ingress-operator
REGISTRY_AUTH_FILE=~/.docker-build/config.json \
  REPO=quay.io/danclark/cluster-ingress-operator make release-local

TAG=$(git rev-parse --short HEAD)
skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/cluster-ingress-operator:${TAG} | jq -r .Digest
```

The tag is the short commit SHA.

---

## cloud-provider-azure

Builds with docker. `DOCKER_CONFIG` points the Makefile's internal `docker`
calls at the build auth context so base-image pulls resolve.

```bash
cd ~/workspace/cloud-provider-azure
DOCKER_CONFIG=~/.docker-build \
  ARCH=amd64 IMAGE_REGISTRY=quay.io/danclark make build-ccm-image

TAG=$(git rev-parse --short HEAD)
docker --config ~/.docker-build push \
  quay.io/danclark/azure-cloud-controller-manager:${TAG}

skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/azure-cloud-controller-manager:${TAG} | jq -r .Digest
```

The build produces several images (arm64, Windows); only the amd64 cloud
controller manager is needed.

The original notes said the Makefile had to be edited to use the
OpenShift-specific Dockerfiles. **That is no longer needed** — the fork branch
already points at
`openshift-hack/images/cloud-controller-manager-openshift.Dockerfile`, and the
build runs from a clean checkout.

> **Open question — `azure-cloud-node-manager`.** It *is* a component of the
> release payload, and the release currently ships the **stock** image. The
> fork's patch is in `pkg/azclient/cloud.go`, and the node manager imports
> `pkg/provider` exactly as the controller manager does, so it may reach the
> same cloud-config resolution path. Static inspection was not conclusive:
> `GetAzureCloudConfigAndEnvConfig` has no first-party callers outside
> `pkg/azclient`.
>
> If it turns out to be needed, the Makefile already has a `build-node-image`
> target using `cloud-node-manager-openshift.Dockerfile`, and it would be
> overridden as the `azure-cloud-node-manager` release component. Building it
> regardless is cheap insurance for a test release.

---

## machine-api-provider-azure

```bash
cd ~/workspace/machine-api-provider-azure
podman build --authfile ~/.docker-build/config.json \
  -t quay.io/danclark/machine-api-provider-azure:4.21 \
  -f Dockerfile.rhel .

podman push --authfile ~/.docker-build/config.json \
  quay.io/danclark/machine-api-provider-azure:4.21

skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/machine-api-provider-azure:4.21 | jq -r .Digest
```

Tagged `4.21` rather than by commit SHA.

---

## azure-disk-csi-driver

The most involved of the six, for two reasons.

### It needs RHEL entitlements

The build runs `dnf install` inside the container, so it needs entitlement
certificates bind-mounted from the host. RHUI certificates from an AWS RHEL
AMI will not work — the host must be registered with `subscription-manager`.
`prereq.sh` offers to do this.

### The certificate filenames are host-specific

Entitlement certs are named with a long random number that differs per host,
and both the Makefile and `Dockerfile.openshift.rhel7` reference them
literally. Find yours and patch both files:

```bash
ls /etc/pki/entitlement/*.pem
# e.g. 3326347401626801700.pem and 3326347401626801700-key.pem
```

`build/azure-disk-csi-driver.sh` detects the cert and rewrites both files
automatically.

### Build and push

```bash
cd ~/workspace/azure-disk-csi-driver
DOCKER_CONFIG=~/.docker-build \
  REGISTRY=quay.io/danclark OUTPUT_TYPE=docker make container-linux

docker --config ~/.docker-build push \
  quay.io/danclark/azuredisk-csi:v1.34.2-linux-amd64

skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/azuredisk-csi:v1.34.2-linux-amd64 | jq -r .Digest
```

`OUTPUT_TYPE=docker` is required. The Makefile defaults to
`OUTPUT_TYPE=registry`, which pushes during the build and fails on the quay.io
auth split described in the README. Building to the local docker daemon and
pushing separately avoids it.

---

## cluster-config-operator

```bash
cd ~/workspace/cluster-config-operator
podman build --authfile ~/.docker-build/config.json \
  -f Dockerfile.rhel7 \
  -t quay.io/danclark/cluster-config-operator:latest .

podman push --authfile ~/.docker-build/config.json \
  quay.io/danclark/cluster-config-operator:latest

skopeo inspect --authfile ~/.docker-build/config.json \
  docker://quay.io/danclark/cluster-config-operator:latest | jq -r .Digest
```

The repo's `make image-ocp-cluster-config-operator` target needs
`imagebuilder`; building the Dockerfile directly avoids that dependency.

---

## installer

Produces a binary, not a container image, so it is not part of
`oc adm release new`. It is used to deploy the custom release.

```bash
cd ~/workspace/installer
./hack/build.sh
# -> bin/openshift-install  (~686 MB)
```

Expect **roughly 30 minutes**: `hack/build.sh` compiles a sub-binary for every
cloud provider.

---

## Install-time note

Deploying the result needs one manual step that is not part of this build:
take the RHCOS VHD, upload it to an Azure storage account, generate a SAS URL,
and set it as `platform.azure.clusterOSImage` in the install config.

## Next

[Building the custom release](custom-release.md)
