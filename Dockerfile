# Hypermemetic infrastructure development image
# Rust + Haskell + common dev tools on the claude-container base
#
# Usage:
#   claude-container -s myproj --dockerfile Dockerfile

FROM ghcr.io/hypermemetic/claude-container:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive

# System dependencies + dev tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials
    build-essential \
    pkg-config \
    libssl-dev \
    cmake \
    # Haskell native deps
    libgmp-dev \
    libffi-dev \
    libncurses-dev \
    libtinfo-dev \
    zlib1g-dev \
    # SQLite (substrate sqlx)
    libsqlite3-dev \
    sqlite3 \
    # Common dev tools
    jq \
    htop \
    tree \
    ripgrep \
    fd-find \
    sudo \
    less \
    vim-tiny \
    strace \
    net-tools \
    dnsutils \
    iputils-ping \
    # Docker CLI
    docker.io \
    && rm -rf /var/lib/apt/lists/* \
    # yq (YAML processor)
    && YQ_ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}" \
       -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Rust — already installed in base, add extra components
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH

RUN curl -L --proto '=https' --tlsv1.2 -sSf \
    https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh \
    | bash \
    && rustup component add rust-analyzer 2>/dev/null || true \
    && cargo binstall -y sqlx-cli

# Haskell via GHCup
ENV GHCUP_INSTALL_BASE_PREFIX=/usr/local \
    PATH=/usr/local/.ghcup/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | \
    BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
    BOOTSTRAP_HASKELL_GHC_VERSION=9.4.8 \
    BOOTSTRAP_HASKELL_CABAL_VERSION=latest \
    BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 \
    sh \
    && ghcup install ghc 9.4.8 --set \
    && ghcup install cabal latest --set \
    && cabal update \
    && chmod -R a+rwX /usr/local/.ghcup /root/.cabal 2>/dev/null || true

# Node.js + Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Runtime defaults
ENV RUST_LOG=info \
    RUST_BACKTRACE=1 \
    SQLX_OFFLINE=true

WORKDIR /workspace
