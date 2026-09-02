#!/usr/bin/env bash
#
# Pushes the packages built by generate.sh to their own GitHub repositories.
# Each target repository is cloned, its managed content is replaced with the
# freshly generated tree, and the result is committed only if something
# actually changed.

set -euo pipefail

OUT_DIR="${OUT_DIR:-/workspace/build}"
WORK_DIR="${WORK_DIR:-/tmp/protogen-publish}"

GO_REPO="${GO_REPO:-github.com/giedrius-slegeris/proto-definitions-go}"
PHP_REPO="${PHP_REPO:-github.com/giedrius-slegeris/proto-definitions-php}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"

GIT_USER_NAME="${GIT_USER_NAME:-proto-definitions bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-proto-definitions-bot@users.noreply.github.com}"

RELEASE_TAG="${RELEASE_TAG:-}"
DRY_RUN="${DRY_RUN:-0}"

# Paths in the target repositories that this script must never delete, so a
# target repo can carry its own CI without it being wiped on every publish.
KEEP_PATHS="${KEEP_PATHS:-.github}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN is not set (copy .env.example to .env)"

# --------------------------------------------------------------------------
# Commit message: describe the source revision that produced this output.
# --------------------------------------------------------------------------
source_rev="${SOURCE_SHA:-}"
if [ -z "$source_rev" ] && git -C /workspace rev-parse --short HEAD >/dev/null 2>&1; then
    source_rev="$(git -C /workspace rev-parse --short HEAD)"
fi
[ -n "$source_rev" ] || source_rev="unknown"

COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore: regenerate from proto-definitions@${source_rev}}"

git config --global user.name  "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
# Silence the "which merge strategy" hint; we only ever fast-forward.
git config --global pull.rebase true

# Never let the token reach a log line or the cloned repo's .git/config.
auth_url() {
    printf 'https://x-access-token:%s@%s.git' "$GITHUB_TOKEN" "$1"
}

# publish_package <label> <repo-slug> <source-tree>
publish_package() {
    local label="$1" repo="$2" src="$3"
    local dir="$WORK_DIR/$label"

    [ -d "$src" ] || die "$label: nothing to publish, $src does not exist (run generate first)"

    log "[$label] cloning https://$repo"
    rm -rf "$dir"
    mkdir -p "$dir"
    if ! git clone --quiet --depth 1 "$(auth_url "$repo")" "$dir" 2>/dev/null; then
        die "$label: could not clone https://$repo — check the repo exists and GITHUB_TOKEN has write access"
    fi

    # Keep the token out of .git/config; it is supplied per-command instead.
    git -C "$dir" remote set-url origin "https://$repo.git"

    # A brand-new empty repository clones with no branch at all.
    if ! git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1; then
        log "[$label] repository is empty, starting branch $TARGET_BRANCH"
        git -C "$dir" checkout --quiet -b "$TARGET_BRANCH"
    else
        git -C "$dir" checkout --quiet -B "$TARGET_BRANCH" HEAD
    fi

    # Replace the managed content. Everything is regenerated, so stale files
    # from removed protos have to disappear too.
    log "[$label] replacing generated content"
    local keep_args=()
    local keep
    for keep in $KEEP_PATHS; do
        keep_args+=(-not -path "./$keep" -not -path "./$keep/*")
    done
    (
        cd "$dir"
        find . -mindepth 1 -maxdepth 1 \
            -not -name .git \
            "${keep_args[@]}" \
            -exec rm -rf {} +
    )
    cp -a "$src/." "$dir/"

    git -C "$dir" add -A

    if git -C "$dir" diff --cached --quiet; then
        log "[$label] generated output is unchanged"
    else
        git -C "$dir" --no-pager diff --cached --stat | sed 's|^|    |'

        if [ "$DRY_RUN" = "1" ]; then
            warn "[$label] DRY_RUN=1, not committing or pushing"
            return 0
        fi

        git -C "$dir" commit --quiet -m "$COMMIT_MESSAGE"
        log "[$label] pushing to $TARGET_BRANCH"
        git -C "$dir" push --quiet "$(auth_url "$repo")" "HEAD:refs/heads/$TARGET_BRANCH"
        log "[$label] published"
    fi

    # A release tag is pushed even when the content is unchanged, so that
    # `make release TAG=...` is always able to cut a version.
    if [ -n "$RELEASE_TAG" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            warn "[$label] DRY_RUN=1, not tagging $RELEASE_TAG"
        elif git -C "$dir" ls-remote --exit-code --tags \
                "$(auth_url "$repo")" "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
            warn "[$label] tag $RELEASE_TAG already exists on the remote, leaving it alone"
        else
            log "[$label] tagging $RELEASE_TAG"
            git -C "$dir" tag -a "$RELEASE_TAG" -m "$RELEASE_TAG"
            git -C "$dir" push --quiet "$(auth_url "$repo")" "refs/tags/$RELEASE_TAG"
        fi
    fi
}

mkdir -p "$WORK_DIR"
publish_package go  "$GO_REPO"  "$OUT_DIR/go"
publish_package php "$PHP_REPO" "$OUT_DIR/php"
rm -rf "$WORK_DIR"

log "All packages published"
