#!/usr/bin/env bash
# Prints, as one JSON array, every image the repository builds, for the publish job's matrix:
#   [{"image":"elysium-prince-core-api","context":"Prince/Backend","file":"Prince/Backend/Core/Dockerfile"}, ...]
# The images come from each service's docker-compose.yml (<Service>/docker-compose.yml): every Compose service
# with a `build` section is one image, named elysium-<service folder>-<compose service>, lower case.
# Compose already holds each image's build context and Dockerfile, so adding an image needs no workflow change.
# Fails when a Dockerfile in the repository is built by no Compose service (it would silently never be
# published), or when a build uses settings the publish job doesn't pass on (build args, target).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

images='[]'
status=0

while IFS= read -r compose; do
    dir="$(dirname "$compose")"
    dir="${dir#./}"
    if [ "$dir" = "." ]; then
        echo "$compose: a root docker-compose.yml has no service folder to name its images after; extend $0" >&2
        exit 1
    fi
    service="$(basename "$dir" | tr '[:upper:]' '[:lower:]')"

    # --no-interpolate: no .env is needed, and contexts come back as absolute paths
    builds="$(docker compose -f "$compose" config --no-interpolate --format json |
        jq -c '[.services | to_entries[] | select(.value.build) | {name: .key, build: .value.build}]')"

    unsupported="$(jq -r '.[] | select(.build | has("args") or has("target")) | .name' <<<"$builds")"
    if [ -n "$unsupported" ]; then
        echo "$compose: build args or target are not passed on by the publish job: $unsupported" >&2
        status=1
    fi

    images="$(jq -c --arg root "$root/" --arg service "$service" --argjson builds "$builds" '
        . + [$builds[] | (.build.context | ltrimstr($root)) as $context | {
            image: ("elysium-" + $service + "-" + .name | ascii_downcase),
            context: $context,
            file: ($context + "/" + (.build.dockerfile // "Dockerfile"))
        }]' <<<"$images")"
done < <(find . -name docker-compose.yml -not -path '*/node_modules/*' -not -path './.claude/*' -not -path './.git/*' | sort)

# Every Dockerfile must be built by some Compose service
while IFS= read -r dockerfile; do
    dockerfile="${dockerfile#./}"
    if ! jq -e --arg f "$dockerfile" 'any(.[]; .file == $f)' <<<"$images" >/dev/null; then
        echo "$dockerfile: no docker-compose.yml service builds it, so it would never be published" >&2
        status=1
    fi
done < <(find . -name Dockerfile -not -path '*/node_modules/*' -not -path './.claude/*' -not -path './.git/*' | sort)

duplicates="$(jq -r 'group_by(.image)[] | select(length > 1) | .[0].image' <<<"$images")"
if [ -n "$duplicates" ]; then
    echo "Two Compose services map to the same image name: $duplicates" >&2
    status=1
fi

[ "$status" -eq 0 ] || exit "$status"
jq -c 'sort_by(.image)' <<<"$images"
