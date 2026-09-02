# proto-definitions

Protocol buffer definitions for the OpenWeatherMap store API, and the
Dockerised toolchain that compiles them into language packages and publishes
those packages to their own repositories.

| Language | Published to |
| -------- | ------------ |
| Go       | [giedrius-slegeris/proto-definitions-go](https://github.com/giedrius-slegeris/proto-definitions-go) |
| PHP      | [giedrius-slegeris/proto-definitions-php](https://github.com/giedrius-slegeris/proto-definitions-php) |

This repository is the single source of truth. The two package repositories are
generated output — never edit them by hand.

## Requirements

Docker with the Compose plugin, `make`, and a GitHub token. Nothing else needs
to be installed locally: `protoc` and every plugin lives in the image.

`docker-compose.yml` uses the host network namespace for both the build and the
run (`build.network: host` / `network_mode: host`). On hosts where
`/etc/resolv.conf` points at a loopback stub — systemd-resolved's `127.0.0.53`,
which is the default on Ubuntu — Docker cannot pass that resolver to containers
and falls back to public DNS, so without this `apk`, `proxy.golang.org` and
`github.com` are all unreachable from inside. Remove those two lines if your
daemon already gives containers a working resolver.

## Setup

```sh
make env       # creates .env from .env.example
$EDITOR .env   # add GITHUB_TOKEN
```

The token needs **Contents: read and write** on both target repositories. A
fine-grained token scoped to just those two repos is the tightest option; a
classic token with the `repo` scope also works. `.env` is git-ignored.

## Usage

```sh
make              # build the image, compile, and publish both packages
make generate     # compile only, into ./build (nothing is pushed)
make dry-run      # compile and show exactly what publishing would change
make lint         # parse-check the .proto files
make release TAG=v1.2.3   # compile, publish, and tag both repositories
make shell        # a shell inside the toolchain image
make clean        # remove ./build, the image and the module cache
make help         # list all targets
```

`make dry-run` is the safe way to preview a change: it clones both target
repositories, stages the regenerated tree and prints the diffstat without
committing or pushing.

Publishing is idempotent — if the generated output is byte-identical to what is
already on the target branch, no commit is created.

## Adding a new definition

Drop the `.proto` file into `protos/` and run `make`. One thing to keep in
sync: the file's `option go_package` must begin with `GO_MODULE` from `.env`,
otherwise the Go import paths come out wrong. For example:

```proto
option go_package = "github.com/giedrius-slegeris/proto-definitions-go/mypackage;mypackage";
```

`make generate` fails with an explicit error if the two disagree, so a mismatch
cannot reach the published repository.

## Versioning

`make` pushes to `main`, which is enough for PHP (`dev-main`) and gives Go
consumers a pseudo-version. For a real version, cut a tag:

```sh
make release TAG=v1.2.3
```

Both repositories get the same tag, so `go get …/proto-definitions-go@v1.2.3`
and `composer require …/proto-definitions-php:v1.2.3` refer to the same
definitions. If a tag already exists on a remote it is left untouched rather
than moved.

## Layout

```
protos/                  the definitions — the only hand-written source here
Dockerfile               protoc + protoc-gen-go + protoc-gen-go-grpc + grpc_php_plugin
docker-compose.yml       mounts the repo into the toolchain image
Makefile                 the entry point
scripts/generate.sh      runs protoc, writes ./build/{go,php}
scripts/publish.sh       clones each target repo, replaces content, commits, pushes
templates/               go.mod, composer.json and README boilerplate for the packages
```

Generated packages land in `./build/`, which is git-ignored. `scripts/publish.sh`
preserves `.github/` in the target repositories (configurable via `KEEP_PATHS`),
so those repos can carry their own CI without it being wiped on every publish.

## License

MIT — see [LICENSE](LICENSE).
