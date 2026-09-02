# syntax=docker/dockerfile:1
#
# Toolchain image for compiling the .proto definitions in this repository into
# Go and PHP packages, and for publishing those packages to their own GitHub
# repositories.
#
# Based on the Go image so that the generated Go module can be tidied and
# compile-checked before it is published.

# Builds with the current Go release; the floor the generated module declares
# for consumers is set by GO_LANG_VERSION in scripts/generate.sh.
FROM golang:1.27-alpine

# protoc is installed from the upstream release rather than from apk, because
# Alpine pins protobuf at 31.1 on every current branch. PROTOC_VERSION and the
# google/protobuf constraint in templates/php/composer.json.tmpl must be kept
# in step: the PHP runtime's minor tracks the protoc major exactly (protoc 36.1
# -> google/protobuf v5.36.x). scripts/generate.sh warns if they drift.
ARG PROTOC_VERSION=36.1
ARG PROTOC_GEN_GO_VERSION=v1.36.12
ARG PROTOC_GEN_GO_GRPC_VERSION=v1.6.2

# grpc-plugins -> grpc_php_plugin (the PHP gRPC stub generator; no upstream
#                 binary is published for it, so apk's build is used)
# libstdc++    -> required by the upstream protoc binary on musl
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        git \
        grpc-plugins \
        libstdc++ \
        openssh-client \
        unzip

# Unpacks to /usr/local/bin/protoc plus the well-known .proto files in
# /usr/local/include, which protoc resolves relative to its own location.
# /usr/local/bin precedes /usr/bin on PATH, so this shadows the protoc that
# grpc-plugins pulls in as a dependency — asserted below so a base image
# change cannot silently downgrade the compiler.
RUN curl -sSLo /tmp/protoc.zip \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-x86_64.zip" \
    && unzip -qo /tmp/protoc.zip -d /usr/local \
    && rm /tmp/protoc.zip \
    && chmod +x /usr/local/bin/protoc \
    && test "$(protoc --version)" = "libprotoc ${PROTOC_VERSION}"

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION} \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@${PROTOC_GEN_GO_GRPC_VERSION}

# The repository is bind-mounted at /workspace, which git would otherwise
# refuse to touch because it is owned by a different uid than root.
RUN git config --global --add safe.directory '*'

COPY scripts/   /opt/protogen/scripts/
COPY templates/ /opt/protogen/templates/
RUN chmod +x /opt/protogen/scripts/*.sh

ENV PROTO_DIR=/workspace/protos \
    OUT_DIR=/workspace/build \
    TEMPLATE_DIR=/opt/protogen/templates

WORKDIR /workspace

ENTRYPOINT ["/opt/protogen/scripts/entrypoint.sh"]
CMD ["all"]
