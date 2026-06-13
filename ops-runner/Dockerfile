# Ops-runner image for running cluster tooling (verify-experiments etc.) from
# nazgul as a Pelagos container. Tooling only — the repo and SSH key are
# bind-mounted at run time so the image stays generic and the repo stays current.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-client \
        python3 \
        bash \
        git \
        rsync \
        curl \
        ca-certificates \
        procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
ENTRYPOINT ["/bin/bash"]
