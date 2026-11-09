# syntax=docker/dockerfile:1

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf \
        bash \
        bc \
        binutils \
        bison \
        build-essential \
        cmake \
        cmake-doc \
        coreutils \
        curl \
        extra-cmake-modules \
        findutils \
        flex \
        g++ \
        gawk \
        gcc \
        gfortran \
        git \
        gnupg \
        gperf \
        grep \
        jq \
        libargon2-dev \
        libarpack2-dev \
        libblas-dev \
        libbz2-dev \
        libcurl4-openssl-dev \
        libffi-dev \
        libfftw3-dev \
        libglpk-dev \
        libgmp-dev \
        liblapack-dev \
        liblzma-dev \
        libmpfr-dev \
        libncurses-dev \
        libonig-dev \
        libpcre2-dev \
        libqhull-dev \
        libqrupdate-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libsuitesparse-dev \
        libsundials-dev \
        libxml2 \
        libxml2-dev \
        linux-headers-$(dpkg --print-architecture) \
        pciutils \
        perl \
        pkg-config \
        python-is-python3 \
        python3 \
        python3-pip \
        sqlite3 \
        unzip \
        usbutils \
        util-linux \
        xz-utils \
        zip \
        zlib1g-dev && \
    ln -sf /bin/bash /bin/sh && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh mkindex.sh serve.py /

# Package builds run as root to compile toolchains and write mounted outputs.
ENTRYPOINT ["bash", "/entrypoint.sh"]
CMD ["--no-build"]
