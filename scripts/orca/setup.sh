#!/usr/bin/env bash
# Orca setup hook: prepares a new worktree so the site builds.
# Runs from the worktree root.
set -euo pipefail

echo "==> theme submodule"
git submodule update --init --recursive

echo "==> hugo"
scripts/orca/hugo.sh version

echo "==> done"
