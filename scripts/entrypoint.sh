#!/usr/bin/env bash
#
# Dispatches to the generate / publish scripts. Anything unrecognised is run
# verbatim so that `docker compose run --rm protoc protoc --version` works.

set -euo pipefail

SCRIPTS=/opt/protogen/scripts

command="${1:-all}"
[ $# -gt 0 ] && shift

case "$command" in
    generate)
        exec "$SCRIPTS/generate.sh" "$@"
        ;;
    publish)
        exec "$SCRIPTS/publish.sh" "$@"
        ;;
    all)
        "$SCRIPTS/generate.sh"
        exec "$SCRIPTS/publish.sh"
        ;;
    shell|sh|bash)
        exec bash "$@"
        ;;
    *)
        exec "$command" "$@"
        ;;
esac
