#!/usr/bin/env bash
# Orca run command: serves the site with drafts and live reload.
# Uses the first free port from 1313, so several worktrees can run at once.
# Listens on all interfaces so the site can be opened from other machines;
# links use the Tailscale IP (or the first LAN IP). Override with BIND and HOST,
# e.g. BIND=127.0.0.1 HOST=localhost for local-only.
# Extra arguments go to `hugo server`.
set -euo pipefail

cd "${ORCA_WORKTREE_PATH:-$(git rev-parse --show-toplevel)}"

# Worktrees created before setup.sh existed may lack the theme.
[[ -e themes/typo/theme.toml ]] || git submodule update --init --recursive

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
PORT="${PORT:-1313}"
while port_in_use "$PORT"; do PORT=$((PORT + 1)); done

BIND="${BIND:-0.0.0.0}"
if [[ -z "${HOST:-}" ]]; then
  HOST="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  [[ -n "$HOST" ]] || HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$HOST" ]] || HOST=localhost
fi

echo "==> http://${HOST}:${PORT}/"
exec scripts/orca/hugo.sh server \
  --buildDrafts --buildFuture \
  --bind "$BIND" --port "$PORT" --baseURL "http://${HOST}:${PORT}/" \
  --disableFastRender "$@"
