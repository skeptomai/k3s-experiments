# Personal dev pod: an SSH-reachable, long-running x86_64 Linux dev
# environment for local-edit/remote-build workflows (see
# docs/personal-dev-pod.md). Base on rust:1-bookworm since Rust is the
# most demanding case this needs to serve and it has broad apt
# availability for anything else added later.
#
# This is the first SSH-server image in either repo -- everything else
# here (pelagos-builder, ops-runner, the various *-image builders) is
# Job-style/one-shot. Entry point is sshd -D (long-running), not a
# one-shot command.
FROM rust:1-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        openssh-server \
        git \
        build-essential \
        curl \
        ca-certificates \
        sudo \
        vim \
        less \
        procps \
        rsync \
    ; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd

# rust:1-bookworm's rustup/cargo/rustc do NOT include rust-analyzer -- it's
# a separate rustup component. Without this, `rust-analyzer` on PATH is
# just rustup's dispatch proxy (present, but errors "Unknown binary
# 'rust-analyzer' in official toolchain..." on every invocation since no
# component backs it), which looks like the LSP server crashing/restarting
# in an Emacs/rustic-mode client rather than a missing-install problem.
# Confirmed 2026-09-29 live on this exact symptom.
RUN rustup component add rust-analyzer

# Non-root dev user. UID/GID are arbitrary -- this is an isolated
# container, not sharing files with the physical nodes. The actual home
# directory content comes from the NFS-backed PVC mounted at /home/cb at
# runtime (see manifests/personal-dev-pod/deployment.yaml), not this image.
RUN useradd --create-home --shell /bin/bash --uid 1000 cb \
    && usermod -aG sudo cb \
    && echo 'cb ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cb \
    && chmod 0440 /etc/sudoers.d/cb

# SSH login sessions go through PAM, not the container's ENTRYPOINT/ENV --
# Docker/OCI `ENV` (PATH/CARGO_HOME/RUSTUP_HOME, set by the rust:1-bookworm
# base) is only inherited by processes the container runtime execs
# directly, not by sshd-spawned login shells. Without this, `ssh
# cb@devbox... cargo build` fails with "cargo: command not found" even
# though the toolchain is right there. pam_env reads /etc/environment for
# every SSH session (interactive or a single remote command), so mirror
# the base image's toolchain env vars there explicitly.
RUN { \
      echo 'PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; \
      echo 'CARGO_HOME=/usr/local/cargo'; \
      echo 'RUSTUP_HOME=/usr/local/rustup'; \
    } >> /etc/environment

# sshd: pubkey-only, no password/root login. See sshd_config for the
# HostKey paths -- those point at a persistent subPath on the same PVC
# (via entrypoint.sh) so host keys survive reschedule too, avoiding
# "host key changed" warnings on every pod recreation.
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
