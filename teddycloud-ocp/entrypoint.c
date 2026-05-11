/*
 * tc-entrypoint.c — capability-safe entrypoint for TeddyCloud on OpenShift.
 *
 * Problem:
 *   The upstream wrapper is a bash script.  bash has no file capabilities,
 *   so after runc execs bash, the process CapPrm drops to 0.  With
 *   allowPrivilegeEscalation=false (no_new_privs=1) the kernel caps
 *   P'(permitted) to P(permitted)=0, so teddycloud can never inherit
 *   NET_BIND_SERVICE even though setcap was applied to it.
 *
 * Fix:
 *   This binary has setcap cap_net_bind_service=+ep applied.  runc execs it
 *   directly (exec-form ENTRYPOINT), so at the execve the kernel sees
 *   F(permitted)=NET_BIND_SERVICE and P(bounding)=NET_BIND_SERVICE, and
 *   because P(permitted) also equals NET_BIND_SERVICE at that moment the
 *   no_new_privs clamp (P'(permitted) &= P(permitted)) is satisfied.
 *   We then execv teddycloud, which also carries +ep file caps, preserving
 *   the capability through to the listener.
 */

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

int main(void)
{
    /* Ensure cert directories exist on the PVC (best-effort, ignore errors). */
    mkdir("/teddycloud/certs",        0755);
    mkdir("/teddycloud/certs/server", 0755);
    mkdir("/teddycloud/certs/client", 0755);

    /* Match the upstream wrapper's working directory. */
    if (chdir("/teddycloud") != 0) {
        perror("chdir /teddycloud");
        /* Non-fatal: teddycloud locates config via absolute paths as well. */
    }

    /* Suppress AddressSanitizer's leak detector — the upstream binary is a
     * debug build that reports leaks on every clean exit, which would cause
     * the container to exit with a non-zero code for no good reason.        */
    setenv("LSAN_OPTIONS", "detect_leaks=0", 0 /* don't overwrite if set */);

    char *const argv[] = { "/usr/local/bin/teddycloud", NULL };
    execv("/usr/local/bin/teddycloud", argv);

    perror("execv /usr/local/bin/teddycloud failed");
    return 1;
}
