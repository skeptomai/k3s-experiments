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
    ; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd

# Non-root dev user. UID/GID are arbitrary -- this is an isolated
# container, not sharing files with the physical nodes. The actual home
# directory content comes from the NFS-backed PVC mounted at /home/cb at
# runtime (see manifests/personal-dev-pod/deployment.yaml), not this image.
RUN useradd --create-home --shell /bin/bash --uid 1000 cb \
    && usermod -aG sudo cb \
    && echo 'cb ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cb \
    && chmod 0440 /etc/sudoers.d/cb

# sshd: pubkey-only, no password/root login. See sshd_config for the
# HostKey paths -- those point at a persistent subPath on the same PVC
# (via entrypoint.sh) so host keys survive reschedule too, avoiding
# "host key changed" warnings on every pod recreation.
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
