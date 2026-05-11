# Security Context Constraints (SCCs) in OpenShift

## 1. What SCCs are for

By default, OpenShift follows the principle of least privilege: every container starts with almost no OS-level powers, regardless of what the image was built for.

**SCCs define what a workload is allowed to request.** They act as a mandatory admission controller on top of Kubernetes' standard Pod Security Admission.

When you submit a Pod, OpenShift:
1. Looks up the `ServiceAccount` the Pod runs as.
2. Finds which SCCs that account is permitted to use.
3. Checks whether the Pod's requested privileges (capabilities, UID range, host access, etc.) fall within those SCCs.
4. Rejects the Pod before scheduling if they do not.

---

## 2. How SCCs map to the OS

Linux does not know what an SCC is. It only knows **capabilities** — roughly 40 discrete units of privilege that replace the traditional all-or-nothing root model.

| Capability | What it allows |
|------------|---------------|
| `NET_BIND_SERVICE` | Bind to ports 1–1023 |
| `CHOWN` | Change file ownership |
| `SYS_TIME` | Change the system clock |

When OpenShift admits a Pod, it translates the SCC into an OCI security profile and passes it to the container runtime (`CRI-O`). CRI-O then configures the Linux kernel's capability sets for the container's initial process.

**The SCC is therefore an OpenShift-level policy; the actual enforcement happens in the kernel via capability bits.**

---

## 3. The three Linux capability sets

Linux tracks capabilities in three per-process sets. All three are visible in `/proc/<pid>/status`.

| Set | Role |
|-----|------|
| **`CapBnd`** (Bounding) | Hard ceiling. A process can never gain a cap absent from this set, no matter what else is configured. |
| **`CapPrm`** (Permitted) | Caps the process may activate into Effective. |
| **`CapEff`** (Effective) | What the kernel **actually checks** on every syscall. `bind()`, `chown()`, etc. consult this set. |

The critical point: **`CapBnd` having a bit set means the cap is not forbidden. It does not mean the process holds it.** A cap in `CapBnd` but absent from `CapEff` is invisible to the kernel during syscall checks.

---

## 4. What the image must provide: `setcap`

Listing a capability in `securityContext.capabilities.add` in the Pod spec tells OpenShift to allow it in `CapBnd`. Under `restricted-v2` with a high non-root UID, this commonly produces:

```
CapBnd: 0000000000000400   ← NET_BIND_SERVICE: not forbidden
CapPrm: 0000000000000000   ← never promoted to permitted
CapEff: 0000000000000000   ← kernel sees nothing → bind() → EPERM
```

The missing step is promoting the cap from `CapBnd` into `CapPrm`/`CapEff`. This happens at `execve` when the **binary itself carries file capabilities**, set during the image build with `setcap`.

`setcap cap_net_bind_service=+ep` means:
- `+p` → add to **Permitted**
- `+e` → add to **Effective**

At `execve`, the kernel reads these file capabilities and applies them to the new process's sets — no application source code changes required.

```dockerfile
RUN dnf install -y libcap && dnf clean all
# Install the setcap tool (Ubuntu/Debian)
# RUN apt-get install -y --no-install-recommends libcap2-bin

# Attach file capabilities to the binary
RUN setcap 'cap_net_bind_service=+ep' /usr/local/bin/my-app

# OpenShift assigns a GID-0 container user; ensure the binary is accessible
RUN chown :0 /usr/local/bin/my-app && chmod 755 /usr/local/bin/my-app

# Declare a non-root user
USER 1001
```

---

## 5. Runtime walkthrough: `bind(80)` with a non-root process

With the SCC and the image both correctly configured, a single `bind(80)` call goes through three layers:

1. **SCC / admission** — OpenShift admits the Pod and CRI-O puts `NET_BIND_SERVICE` into `CapBnd`. The cap is allowed but not yet held.
2. **`execve` / file caps** — The kernel reads the `setcap` metadata from the binary and promotes `NET_BIND_SERVICE` into `CapPrm` and `CapEff` for the new process. The binary has now "taken" the capability.
3. **`bind()` syscall** — The kernel checks `CapEff`, finds `NET_BIND_SERVICE` present, and allows the bind to port 80. The process is running as UID 1001.

If **step 1 is missing** (SCC does not allow the cap), `CapBnd` blocks it — the Pod may not even be admitted.

If **step 2 is missing** (no `setcap` on the binary), `CapEff` stays zero — `bind()` returns `EPERM` even though the SCC permitted it.

---

## 6. Why a shell entrypoint silently breaks `setcap`

### Parent `CapBnd` is the shared ceiling for the whole process chain

Every child process inherits its parent's `CapBnd` as an absolute ceiling — no `execve` can ever raise it. `CapPrm` and `CapEff` are then further constrained within that ceiling. With `no_new_privs=1` the additional rule `new CapPrm &= parent CapPrm` means `CapPrm` can only go **down**, never up. Whatever the parent dropped is gone for every descendant.

### The shell is the parent — and `setcap` cannot be applied to it

When the OCI entrypoint is a shell script, `bash` is the direct parent of the application process. `setcap` writes file capability metadata into a binary's inode, but a shell script is plain text — the kernel ignores `setcap` on it entirely. Bash therefore starts with **no file capabilities**, its `CapPrm` drops to zero, and it becomes the parent that sets the ceiling for everything below it.

Stamping `setcap` on the application binary alone is then pointless: the formula reads the stamp correctly, but `no_new_privs` clamps the result against the parent's (zero) `CapPrm` before the child ever runs:

```
runc (CapPrm = NET_BIND_SERVICE)
  └─ execve(bash)         no setcap possible on a script → CapPrm = 0
       └─ execve(myapp)   setcap +ep stamp present, but parent CapPrm = 0
                          → no_new_privs clamp: new CapPrm &= 0 = 0
                          → CapEff = 0 → bind(80) → EPERM
```

### The fix

Replace the shell script entrypoint with a **compiled binary** that also carries `setcap +ep`. The container runtime execs it directly, so `CapPrm` is never zeroed before the application is reached:

```
runc (CapPrm = NET_BIND_SERVICE)
  └─ execve(entrypoint)   setcap +ep → new CapPrm = NET_BIND_SERVICE ✓
       └─ execve(myapp)   setcap +ep, parent CapPrm = NET_BIND_SERVICE
                          → no_new_privs clamp: NET_BIND_SERVICE & NET_BIND_SERVICE = NET_BIND_SERVICE ✓
                          → CapEff = NET_BIND_SERVICE → bind(80) succeeds
```
