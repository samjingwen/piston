# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b

ARG NODE_IMAGE=node:26-trixie-slim@sha256:5adad64f9a1fca2d51972caa65983634c8a774eb300d72b20f7f2a0f60368072

FROM ${NODE_IMAGE} AS isolate

ARG ISOLATE_COMMIT=af6db68042c3aa0ded80787fbb78bc0846ea2114
ARG ISOLATE_SHA256=2b9f4da856f9bd3adba18b58126fa9471a8b51cdbdaa221efe4ad36f6bb6b980

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libcap-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --silent --show-error \
        "https://github.com/envicutor/isolate/archive/${ISOLATE_COMMIT}.tar.gz" \
        --output /tmp/isolate.tar.gz && \
    echo "${ISOLATE_SHA256}  /tmp/isolate.tar.gz" | sha256sum --check --strict && \
    mkdir /tmp/isolate && \
    tar xzf /tmp/isolate.tar.gz --directory /tmp/isolate --strip-components=1 && \
    make -C /tmp/isolate -j"$(nproc)" BUILD_COMMIT="${ISOLATE_COMMIT}" install

FROM ${NODE_IMAGE} AS runtime

ARG ISOLATE_COMMIT=af6db68042c3aa0ded80787fbb78bc0846ea2114
ARG VCS_REF=uncommitted

LABEL org.opencontainers.image.source="https://github.com/engineer-man/piston" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.description="Piston API with Isolate" \
      org.piston.isolate.revision="${ISOLATE_COMMIT}"

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production

RUN dpkg-reconfigure -p critical dash
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        coreutils \
        e2fsprogs \
        gnupg \
        libc6-dev \
        libarpack2-dev \
        libblas-dev \
        libcap-dev \
        libedit-dev \
        libevent-dev \
        libfftw3-dev \
        libglpk-dev \
        libgmp-dev \
        liblapack-dev \
        libncurses6 \
        libpcre2-dev \
        libqhull-dev \
        libqrupdate-dev \
        libreadline-dev \
        libseccomp-dev \
        libsuitesparse-dev \
        libsundials-dev \
        libxml2 \
        locales \
        procps \
        python3 \
        rename \
        tar \
        util-linux && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --no-create-home piston

COPY --from=isolate /usr/local/bin/isolate /usr/local/bin/isolate
COPY --from=isolate /usr/local/etc/isolate /usr/local/etc/isolate

RUN test -u /usr/local/bin/isolate && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen

WORKDIR /piston_api

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && \
    npm audit --omit=dev --audit-level=low && \
    rm -rf \
        /root/.npm \
        /usr/local/bin/npm \
        /usr/local/bin/npx \
        /usr/local/lib/node_modules/npm

COPY ./src ./src

EXPOSE 2000/tcp

# Startup requires root to initialize cgroup v2, package ownership, and bounded storage.
# The root supervisor runs the Node API worker as the unprivileged piston user.
CMD ["/piston_api/src/docker-entrypoint.sh"]
