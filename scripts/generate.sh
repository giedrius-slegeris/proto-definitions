#!/usr/bin/env bash
#
# Compiles every .proto file under $PROTO_DIR into two ready-to-publish
# packages:
#
#   $OUT_DIR/go   a Go module ($GO_MODULE) with messages and gRPC stubs
#   $OUT_DIR/php  a Composer package with messages and gRPC client stubs

set -euo pipefail

PROTO_DIR="${PROTO_DIR:-/workspace/protos}"
OUT_DIR="${OUT_DIR:-/workspace/build}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/opt/protogen/templates}"

GO_MODULE="${GO_MODULE:-github.com/giedrius-slegeris/proto-definitions-go}"
# The floor consumers must meet, deliberately one release behind the toolchain
# in the Dockerfile. `go mod tidy` only ever raises it, never lowers it, so a
# dependency needing more will show up in the published go.mod.
GO_LANG_VERSION="${GO_LANG_VERSION:-1.26}"
PHP_PACKAGE="${PHP_PACKAGE:-giedrius-slegeris/proto-definitions-php}"

GO_OUT="$OUT_DIR/go"
PHP_OUT="$OUT_DIR/php"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$PROTO_DIR" ] || die "proto directory not found: $PROTO_DIR"

mapfile -t PROTO_FILES < <(find "$PROTO_DIR" -type f -name '*.proto' | sort)
[ "${#PROTO_FILES[@]}" -gt 0 ] || die "no .proto files found in $PROTO_DIR"

log "Compiling ${#PROTO_FILES[@]} proto file(s) with $(protoc --version)"

# --------------------------------------------------------------------------
# Parse check before writing anything, so a syntax error never leaves a
# half-generated tree behind.
# --------------------------------------------------------------------------
protoc -I "$PROTO_DIR" -o /dev/null "${PROTO_FILES[@]}" \
    || die "proto files failed to parse"

rm -rf "$GO_OUT" "$PHP_OUT"
mkdir -p "$GO_OUT" "$PHP_OUT/src"

# --------------------------------------------------------------------------
# Go
# --------------------------------------------------------------------------
log "Generating Go package ($GO_MODULE)"
protoc -I "$PROTO_DIR" \
    --go_out="$GO_OUT" --go_opt=module="$GO_MODULE" \
    --go-grpc_out="$GO_OUT" --go-grpc_opt=module="$GO_MODULE" \
    "${PROTO_FILES[@]}"

# --go_opt=module strips $GO_MODULE from the output paths, which only works if
# every `option go_package` starts with it. If one does not, protoc-gen-go
# writes the full import path as a directory tree instead — catch that here
# rather than publishing a module with unimportable packages.
if [ -d "$GO_OUT/${GO_MODULE%%/*}" ]; then
    die "GO_MODULE ($GO_MODULE) does not match the 'option go_package' in the .proto files;
       generated tree: $(find "$GO_OUT" -name '*.pb.go' -printf '%P\n' | head -1)"
fi
[ -n "$(find "$GO_OUT" -name '*.pb.go' -print -quit)" ] || die "no Go files were generated"

sed -e "s|{{GO_MODULE}}|$GO_MODULE|g" \
    -e "s|{{GO_LANG_VERSION}}|$GO_LANG_VERSION|g" \
    "$TEMPLATE_DIR/go/go.mod.tmpl" > "$GO_OUT/go.mod"

sed -e "s|{{GO_MODULE}}|$GO_MODULE|g" \
    "$TEMPLATE_DIR/go/README.md.tmpl" > "$GO_OUT/README.md"

# Best effort: resolve the dependency graph and make sure the generated code
# actually compiles. Needs network access; a failure here is not fatal because
# the consuming project resolves its own go.sum anyway.
log "Verifying the generated Go module"
if (cd "$GO_OUT" && go mod tidy && go build ./...); then
    log "Go module tidied and compiles"
else
    warn "could not tidy/build the Go module (offline?); publishing go.mod as templated"
fi

# --------------------------------------------------------------------------
# PHP
# --------------------------------------------------------------------------
log "Generating PHP package ($PHP_PACKAGE)"
protoc -I "$PROTO_DIR" \
    --php_out="$PHP_OUT/src" \
    --grpc_out="$PHP_OUT/src" \
    --plugin=protoc-gen-grpc=/usr/bin/grpc_php_plugin \
    "${PROTO_FILES[@]}"

sed -e "s|{{PHP_PACKAGE}}|$PHP_PACKAGE|g" \
    "$TEMPLATE_DIR/php/composer.json.tmpl" > "$PHP_OUT/composer.json"

# The PHP runtime's minor version tracks the protoc major exactly (protoc 36.1
# -> google/protobuf v5.36.x). Publishing a composer.json that asks for a
# runtime from a different protoc generation is how this drifts out of date
# unnoticed, so say so loudly.
protoc_major="$(protoc --version | sed -n 's/^libprotoc \([0-9]*\).*/\1/p')"
runtime_minor="$(sed -n 's|.*"google/protobuf".*"[^0-9]*[0-9]*\.\([0-9]*\).*|\1|p' "$PHP_OUT/composer.json")"
if [ -n "$protoc_major" ] && [ -n "$runtime_minor" ] && [ "$protoc_major" != "$runtime_minor" ]; then
    warn "protoc is ${protoc_major}.x but composer.json requests google/protobuf ^?.${runtime_minor}.
       These track each other; update templates/php/composer.json.tmpl or
       PROTOC_VERSION in the Dockerfile."
fi

sed -e "s|{{PHP_PACKAGE}}|$PHP_PACKAGE|g" \
    "$TEMPLATE_DIR/php/README.md.tmpl" > "$PHP_OUT/README.md"

# --------------------------------------------------------------------------
# Shared files + ownership
# --------------------------------------------------------------------------
if [ -f /workspace/LICENSE ]; then
    cp /workspace/LICENSE "$GO_OUT/LICENSE"
    cp /workspace/LICENSE "$PHP_OUT/LICENSE"
fi

# The output lands on a bind mount, so hand it back to the invoking user
# instead of leaving root-owned files in the working tree.
if [ "$(id -u)" = "0" ] && [ -n "${HOST_UID:-}" ]; then
    chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT_DIR"
fi

log "Done. Generated:"
find "$GO_OUT" "$PHP_OUT" -type f | sort | sed 's|^|    |'
