#!/usr/bin/env bash
# Prints `true` when the change from <base> to HEAD touches anything besides Markdown (the build runs), `false`
# when every changed file is a .md file (it doesn't). Fails safe: an unknown base, or no changed file at all,
# prints `true`. Usage: tools/ci-code-changed.sh <base commit or rev>
set -euo pipefail

base="${1:-}"
if ! [[ "$base" =~ ^[0-9a-zA-Z][0-9a-zA-Z^~._/-]*$ ]] || ! git rev-parse --verify -q "$base^{commit}" >/dev/null; then
    echo true
    exit 0
fi

files="$(git diff --name-only "$base" HEAD)"
if [ -z "$files" ]; then
    echo true
elif grep -qv '\.md$' <<<"$files"; then
    echo true
else
    echo false
fi
