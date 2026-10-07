#!/usr/bin/env bash
# Orca run command: serves the site with drafts and live reload.
# Uses the first free port from 1313, so several worktrees can run at once.
# Extra arguments go to `hugo server`.
set -euo pipefail

cd "${ORCA_WORKTREE_PATH:-$(git rev-parse --show-toplevel)}"

# Worktrees created before setup.sh existed may lack the theme.
[[ -e themes/typo/theme.toml ]] || git submodule update --init --recursive

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
PORT="${PORT:-1313}"
while port_in_use "$PORT"; do PORT=$((PORT + 1)); done

echo "==> http://localhost:${PORT}/"
exec scripts/orca/hugo.sh server \
  --buildDrafts --buildFuture \
  --bind 127.0.0.1 --port "$PORT" --baseURL "http://localhost:${PORT}/" \
  --disableFastRender "$@"
