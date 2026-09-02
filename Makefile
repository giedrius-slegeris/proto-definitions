# Compile the proto definitions into Go and PHP packages and publish them to
# their own GitHub repositories.
#
#   make              build the image, generate both packages, publish both
#   make generate     generate only, into ./build
#   make dry-run      generate and show what publishing would change
#   make release TAG=v1.2.3
#
# Configuration lives in .env (see .env.example).

COMPOSE ?= docker compose
SERVICE ?= protoc
RUN      = $(COMPOSE) run --rm

# Exported so docker-compose.yml can pick them up.
export HOST_UID   := $(shell id -u)
export HOST_GID   := $(shell id -g)
export SOURCE_SHA := $(shell git rev-parse --short HEAD 2>/dev/null)

TAG ?=
export RELEASE_TAG := $(TAG)

.DEFAULT_GOAL := all

.PHONY: all build generate publish release dry-run lint shell clean env check-env help

## all: build the image, compile the protos and publish both packages
all: generate publish

## build: build the compiler image
build:
	$(COMPOSE) build

## generate: compile the protos into ./build/go and ./build/php
generate: build
	$(RUN) $(SERVICE) generate

## publish: push ./build/go and ./build/php to their GitHub repositories
publish: check-env
	$(RUN) $(SERVICE) publish

## release: generate, publish and tag both repositories (make release TAG=v1.2.3)
release: check-env
ifeq ($(strip $(TAG)),)
	$(error TAG is required, e.g. make release TAG=v1.2.3)
endif
	$(MAKE) generate
	$(RUN) $(SERVICE) publish

## dry-run: generate and report what publishing would change, without pushing
dry-run: check-env generate
	$(RUN) -e DRY_RUN=1 $(SERVICE) publish

## lint: parse-check the proto files only
lint: build
	$(RUN) $(SERVICE) sh -c 'protoc -I $$PROTO_DIR -o /dev/null $$(find $$PROTO_DIR -name "*.proto") && echo "protos OK"'

## shell: open a shell in the compiler image
shell: build
	$(RUN) $(SERVICE) shell

## clean: remove generated output and the image
clean:
	rm -rf build
	-$(COMPOSE) down --rmi local --volumes

## env: create .env from .env.example if it does not exist yet
env:
	@test -f .env || { cp .env.example .env; echo "created .env — add your GITHUB_TOKEN"; }

check-env:
	@test -f .env || { \
		echo "error: .env is missing. Run 'make env' and add your GITHUB_TOKEN."; \
		exit 1; \
	}
	@grep -Eq '^GITHUB_TOKEN=.+' .env || { \
		echo "error: GITHUB_TOKEN is not set in .env"; \
		exit 1; \
	}

## help: list the available targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //' | \
		awk -F': *' '{ printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2 }'
