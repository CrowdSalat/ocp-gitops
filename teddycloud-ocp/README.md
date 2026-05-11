# teddycloud-ocp

A thin wrapper image around the upstream
[TeddyCloud](https://github.com/toniebox-reverse-engineering/teddycloud) image,
making it run correctly on OpenShift under the default `restricted-v2` Security
Context Constraint (SCC).

## Why this wrapper exists

The upstream TeddyCloud image is designed to run as **root** and binds its HTTP
and HTTPS listeners directly to ports **80** and **443**.

OpenShift's `restricted-v2` SCC forbids running as root and forces every
container to use a high, unpredictable non-root UID (e.g. `1000660000`).
The Linux kernel denies binding to ports below 1024 for processes that do not
hold the `CAP_NET_BIND_SERVICE` capability in their **Effective** capability
set.

Simply adding `CAP_NET_BIND_SERVICE` to `securityContext.capabilities.add` in
the Kubernetes pod spec is not enough for two compounding reasons:

### Problem 1 — shell wrapper resets `CapPrm` to 0

The upstream image uses a **shell script** (`run_teddycloud.sh`) as its OCI
`ENTRYPOINT`. The shell binary itself has no file capabilities, so when the
container runtime execs the shell, the kernel resets `CapPrm` (Permitted) to
zero — even though the runtime placed `NET_BIND_SERVICE` in `CapBnd`
(Bounding):

```
CapBnd: 0000000000000400  ← allowed by SCC, but not yet held
CapPrm: 0000000000000000  ← shell reset this to zero
CapEff: 0000000000000000  ← kernel checks this; it is empty → EPERM
```

### Problem 2 — `no_new_privs` blocks file-capability promotion

`allowPrivilegeEscalation: false` (required by `restricted-v2`) sets the Linux
`no_new_privs` flag. This adds an extra constraint at every subsequent
`execve`: `P'(permitted) &= P(permitted)`. Because the shell's `P(permitted)`
is already 0 (Problem 1), no `execve` in the process chain can ever gain
`NET_BIND_SERVICE`, regardless of `setcap` on the target binary.

### Fix — compiled entrypoint with file capabilities

This wrapper adds two steps during the image build:

1. A small C binary (`tc-entrypoint`) is compiled and given `setcap
   cap_net_bind_service=+ep`.
2. The OCI `ENTRYPOINT` is set to `tc-entrypoint` using the **exec form**
   (JSON array), so the container runtime execs it directly — no shell
   wrapper.

When the runtime execs `tc-entrypoint`, the kernel sees `F(permitted) =
NET_BIND_SERVICE` and `P(bounding) = NET_BIND_SERVICE`, so `P'(permitted) =
NET_BIND_SERVICE`. The `no_new_privs` clamp (`P'(permitted) &= P(permitted) =
NET_BIND_SERVICE`) is now satisfied. `tc-entrypoint` then `execv`s
`teddycloud` (which also carries `+ep`), transferring the capability cleanly
to the final process.

## Quick start

```bash
# Log in to Docker Hub
podman login docker.io

# Build and push (set your Docker Hub username first)
export DOCKERHUB_USER=myusername
./build-push.sh
```

To override the upstream version tag or add a wrapper version suffix:

```bash
UPSTREAM_VERSION=tc_v0.6.9 IMAGE_TAG=tc_v0.6.9-ocp1 ./build-push.sh
```

## Verify file capabilities and entrypoint

After pulling the image, confirm both binaries have `+ep` and the entrypoint
is the compiled wrapper:

```bash
podman run --rm --entrypoint '' <image> sh -c \
  'getcap /usr/local/bin/tc-entrypoint; getcap /usr/local/bin/teddycloud'
# Expected:
# /usr/local/bin/tc-entrypoint  cap_net_bind_service=ep
# /usr/local/bin/teddycloud     cap_net_bind_service=ep
```

## Using the image in OpenShift

Update the `image` field in the TeddyCloud deployment to reference this image,
and keep `securityContext.capabilities.add: [NET_BIND_SERVICE]` in the pod
spec. The SCC must include `NET_BIND_SERVICE` in its allowed capabilities
(the default `restricted-v2` allows it when explicitly requested).
