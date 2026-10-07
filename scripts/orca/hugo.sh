#!/usr/bin/env bash
# Runs the Hugo version the deploy workflow uses, downloading Hugo extended into
# ~/.cache/hugo/<version> once (shared by all worktrees). Falls back to a hugo on
# PATH with the same version.
set -euo pipefail

VERSION="$(sed -n 's/^ *HUGO_VERSION: *//p' .github/workflows/hugo.yaml)"
DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hugo/${VERSION}"

if command -v hugo >/dev/null && hugo version | grep -q "v${VERSION}"; then
  exec hugo "$@"
fi

if [[ ! -x "$DIR/hugo" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset="linux-amd64.tar.gz" ;;
    Linux-aarch64) asset="linux-arm64.tar.gz" ;;
    Darwin-*) asset="darwin-universal.tar.gz" ;;
    *) echo "unsupported platform: $(uname -sm)" >&2; exit 1 ;;
  esac
  echo "==> downloading Hugo extended ${VERSION}" >&2
  mkdir -p "$DIR"
  curl -fsSL "https://github.com/gohugoio/hugo/releases/download/v${VERSION}/hugo_extended_${VERSION}_${asset}" \
    | tar -xz -C "$DIR" hugo
fi

exec "$DIR/hugo" "$@"
