ARG UPSTREAM_VERSION=tc_v0.6.8

FROM ghcr.io/toniebox-reverse-engineering/teddycloud:${UPSTREAM_VERSION}

USER root

# Build a tiny C entrypoint and stamp both it and teddycloud with
# CAP_NET_BIND_SERVICE file capabilities.
#
# Why a compiled entrypoint instead of a shell script:
#   With allowPrivilegeEscalation=false (no_new_privs=1) the kernel rule is
#   P'(permitted) &= P(permitted).  A shell has no file caps, so its CapPrm
#   drops to 0 at execve; the clamp then blocks any further capability
#   promotion.  Executing a compiled binary with +ep file caps directly from
#   runc keeps P(permitted)=NET_BIND_SERVICE throughout the chain.
COPY entrypoint.c /tmp/entrypoint.c
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev libcap2-bin \
    && gcc -O2 -o /usr/local/bin/tc-entrypoint /tmp/entrypoint.c \
    && rm /tmp/entrypoint.c \
    && setcap 'cap_net_bind_service=+ep' /usr/local/bin/tc-entrypoint \
    && setcap 'cap_net_bind_service=+ep' /usr/local/bin/teddycloud \
    && apt-get remove -y gcc libc6-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Exec-form ENTRYPOINT: runc execs tc-entrypoint directly (no shell wrapper).
ENTRYPOINT ["/usr/local/bin/tc-entrypoint"]
