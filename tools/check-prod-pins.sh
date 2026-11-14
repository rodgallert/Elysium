#!/usr/bin/env bash
# Checks docker-compose.prod.yml, the list of what's in production (Docs/workflow.md, Releases).
#
# Always (no network):
# - every service runs a published image (no `build`), written <name>:<tag>@sha256:<64 hex>;
# - the registry is an allowed one;
# - our images (ghcr.io/<owner>/elysium-...) belong to a release part (tools/release-parts.sh) and are tagged
#   with that part's version, x.y.z;
# - third-party tags are not floating: no `latest`, `stable`, ..., and no bare major version (`17-alpine`).
# Unless --offline, against the registry:
# - ours: the digest exists, and the tag, once it exists, points at it (tag and digest agree). A prepared
#   release isn't tagged until its PR merges; that is reported, not failed.
# - third-party: a moved tag or a vanished digest is a warning (upstream rebuilds tags), except as below.
# - --base <ref>: third-party lines added or changed since <ref> must have their tag resolve to their digest
#   now (the multi-arch index digest).
# - --release: every pinned digest, ours and third-party, must exist (a release PR).
#
#   check-prod-pins.sh [--offline] [--base <ref>] [--release] [--owner <owner>] [<compose file>]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
offline=false
release=false
base_ref=""
owner="rodgallert"
while [ $# -gt 0 ]; do
    case "$1" in
        --offline) offline=true; shift ;;
        --release) release=true; shift ;;
        --base) base_ref="$2"; shift 2 ;;
        --owner) owner="$2"; shift 2 ;;
        *) break ;;
    esac
done
file="${1:-$root/docker-compose.prod.yml}"

allowed_registries='^(docker\.io|ghcr\.io|mcr\.microsoft\.com)$'
floating_tags='^(latest|stable|edge|mainline|nightly|lts|current|main|master)$'
bare_major='^v?[0-9]+([-_][a-z][a-z0-9._-]*)?$'

status=0
fail() { echo "$file: $*"; status=1; }
warn() { echo "::warning::$file: $*"; }

# Registry digest of a reference (the index digest for a multi-arch image), empty when it doesn't exist
remote_digest() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' || true
}

parts="$("$root/tools/release-parts.sh")"

# The image lines in the base version of the file, to tell which third-party lines a PR adds or changes
base_images=""
if [ -n "$base_ref" ]; then
    rel="$(realpath --relative-to="$root" "$file")"
    base_file="$(mktemp)"
    trap 'rm -f "$base_file"' EXIT
    if git -C "$root" show "$base_ref:$rel" >"$base_file" 2>/dev/null; then
        base_images="$(docker compose -f "$base_file" config --no-interpolate --format json | jq -r '.services // {} | .[].image // empty')"
    fi
fi

services="$(docker compose -f "$file" config --no-interpolate --format json | jq -c '.services // {} | to_entries')"

while IFS=$'\t' read -r name image build; do
    [ -n "$name" ] || continue
    if [ "$build" = "true" ]; then
        fail "service $name builds from source; production only runs published images"
        continue
    fi
    if ! [[ "$image" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]]; then
        fail "service $name: '$image' has no digest (<name>:<tag>@sha256:<digest>)"
        continue
    fi
    ref="${BASH_REMATCH[1]}"
    digest="${BASH_REMATCH[2]}"
    last="${ref##*/}"
    if [[ "$last" != *:* ]]; then
        fail "service $name: '$image' has no tag (<name>:<tag>@sha256:<digest>)"
        continue
    fi
    tag="${last##*:}"
    repo="${ref%:*}"
    first="${repo%%/*}"
    if [[ "$repo" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
        registry="$first"
    else
        registry="docker.io"
    fi
    if ! [[ "$registry" =~ $allowed_registries ]]; then
        fail "service $name: registry $registry is not allowed (docker.io, ghcr.io, mcr.microsoft.com)"
        continue
    fi

    ours=false
    if [[ "$repo" =~ ^ghcr\.io/$owner/(elysium-[a-z0-9-]+)$ ]]; then
        ours=true
        img="${BASH_REMATCH[1]}"
        part="$(jq -r --arg i "$img" '.[] | select(any(.images[]; .image == $i)) | "\(.part)\t\(.version)"' <<<"$parts")"
        if [ -z "$part" ]; then
            fail "service $name: $img belongs to no release part (no version file for it; see tools/release-parts.sh)"
            continue
        fi
        version="${part#*$'\t'}"
        if [ "$tag" != "$version" ]; then
            fail "service $name: $img is pinned at $tag, but its release part ${part%%$'\t'*} is at '${version:-no version}'"
            continue
        fi
    else
        if [[ "$tag" =~ $floating_tags || "$tag" =~ $bare_major ]]; then
            fail "service $name: tag '$tag' of $repo floats; pin a full version (e.g. 17.6-alpine)"
            continue
        fi
    fi

    $offline && continue

    exists="$(remote_digest "$repo@$digest")"
    tagged="$(remote_digest "$repo:$tag")"

    if $ours; then
        if [ -z "$exists" ]; then
            fail "service $name: $repo@$digest doesn't exist in the registry"
        elif [ -z "$tagged" ]; then
            echo "$file: service $name: $repo:$tag isn't tagged yet (a prepared release, tagged when it merges)"
        elif [ "$tagged" != "$digest" ]; then
            fail "service $name: tag and digest disagree: $repo:$tag is $tagged, the pin says $digest"
        fi
        continue
    fi

    changed=false
    if [ -n "$base_ref" ] && ! grep -qxF "$image" <<<"$base_images"; then changed=true; fi
    if [ -z "$exists" ]; then
        if $release || $changed; then
            fail "service $name: $repo@$digest can't be pulled"
        else
            warn "service $name: $repo@$digest can no longer be pulled; production can't be recreated from this file"
        fi
    fi
    if [ "$tagged" != "$digest" ]; then
        if $changed; then
            fail "service $name: $repo:$tag resolves to ${tagged:-nothing}, not the pinned $digest (pin the tag's current index digest)"
        else
            warn "service $name: upstream moved $repo:$tag to ${tagged:-nothing}; production still runs the pinned $digest"
        fi
    fi
done < <(jq -r '.[] | [.key, (.value.image // ""), (.value | has("build") | tostring)] | @tsv' <<<"$services")

exit "$status"
