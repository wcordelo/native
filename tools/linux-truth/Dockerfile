# Linux truth loop: build + drive every showcase app on real Linux (GTK4)
# under Xvfb, with the repo mounted read-only at /src and all build output
# kept container-local under /work (shared-mount .zig-cache causes host/
# container path and permission skew).
#
# Matches the CI Linux jobs' package set (libgtk-4-dev, libwebkitgtk-6.0-dev,
# xvfb) plus capture/drive tools: x11-apps (xwd) and imagemagick (xwd -> png)
# for window-chrome-level captures alongside the engine screenshot channel.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils rsync \
    libgtk-4-dev libwebkitgtk-6.0-dev \
    xvfb xauth x11-apps x11-utils imagemagick \
    dbus \
    && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
    && ln -s "/opt/zig-aarch64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

# The web process sandbox needs unprivileged user namespaces that container
# seccomp/AppArmor policies restrict; the sandbox is not what this loop
# tests (same setting as the Linux canvas smoke in CI).
ENV WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# No session bus provides an accessibility bus under Xvfb; without this the
# toolkit's accessibility init blocks ~25 s on a bus-name lookup at startup.
ENV GTK_A11Y=none

WORKDIR /work
