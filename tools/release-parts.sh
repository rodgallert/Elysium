#!/usr/bin/env bash
# The versioned parts of every service, as one JSON array. A part is what gets one version, one release tag
# (<part>-v<x.y.z>) and one GitHub Release; every image of a part is released at the part's version.
#
#   [{"part":"prince","service":"prince","folder":"Prince","versionFile":"Prince/Directory.Build.props",
#     "changelog":"Prince/CHANGELOG.md","version":"0.1.0",
#     "images":[{"image":"elysium-prince-core-api","context":"Prince/Backend","file":"Prince/Backend/Core/Dockerfile"}]}]
#
# Where the parts come from:
# - By default a service is one part named after it, versioned by the file at its root that its stack uses:
#   Directory.Build.props (<VersionPrefix>) for .NET, else package.json ("version"). A service without one has
#   no part yet and can't be released.
# - A service with several parts declares them in its docker-compose.yml, and every image belongs to exactly one:
#     x-release-parts:
#       prince-api:                              # the part's name starts with the service's name
#         version: Backend/Directory.Build.props # relative to the service folder
#         images: [core-api, checkout-api]       # Compose service names
# Each part's changelog is the CHANGELOG.md next to its version file.
#
#   release-parts.sh                          every part, with its current version
#   release-parts.sh version <file> [<commit>] the version a file holds (at a commit), empty when it has none
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

fail() { echo "$*" >&2; exit 1; }

read_version() { # <file> [<commit>]
    local content
    if [ -n "${2:-}" ]; then
        content="$(git show "$2:$1" 2>/dev/null)" || return 0
    else
        [ -f "$1" ] || return 0
        content="$(cat "$1")"
    fi
    case "$1" in
        *.props | *.csproj | *.targets)
            grep -oP '<VersionPrefix>\s*\K[^<\s]+' <<<"$content" | head -1 || true ;;
        *package.json)
            jq -r '.version // empty' <<<"$content" 2>/dev/null || true ;;
        *)
            fail "$1: no known way to read a version from this file (Directory.Build.props or package.json)" ;;
    esac
}

if [ "${1:-}" = "version" ]; then
    read_version "${2:?usage: release-parts.sh version <file> [<commit>]}" "${3:-}"
    exit 0
fi

images="$(tools/list-images.sh)"
parts='[]'

while IFS= read -r compose; do
    folder="$(dirname "${compose#./}")"
    service="$(tr '[:upper:]' '[:lower:]' <<<"$folder")"
    declared="$(docker compose -f "$compose" config --no-interpolate --format json | jq -c '."x-release-parts" // {}')"
    mine="$(jq -c --arg f "$folder/" '[.[] | select(.file | startswith($f))]' <<<"$images")"

    if [ "$declared" = "{}" ]; then
        file=""
        for candidate in Directory.Build.props package.json; do
            if [ -f "$folder/$candidate" ]; then file="$folder/$candidate"; break; fi
        done
        [ -n "$file" ] || continue
        declared="$(jq -cn --arg file "${file#"$folder"/}" --argjson mine "$mine" --arg service "$service" \
            '{($service): {version: $file, images: [$mine[] | .image | ltrimstr("elysium-" + $service + "-")]}}')"
    fi

    while IFS=$'\t' read -r part file names; do
        [[ "$part" =~ ^$service(-[a-z0-9]+)*$ ]] || fail "$compose: part '$part' must start with '$service'"
        path="$folder/$file"
        [ -f "$path" ] || fail "$compose: part $part: no version file $path"
        version="$(read_version "$path")"
        parts="$(jq -c --arg part "$part" --arg service "$service" --arg folder "$folder" --arg path "$path" \
            --arg version "$version" --argjson names "$names" --argjson mine "$mine" '
            . + [{part: $part, service: $service, folder: $folder, versionFile: $path,
                  changelog: (($path | split("/") | .[:-1] | join("/")) + "/CHANGELOG.md"),
                  version: $version,
                  images: [$mine[] | select(.image as $i | any($names[]; "elysium-" + $service + "-" + . == $i))]}]' \
            <<<"$parts")"
        missing="$(jq -r --arg part "$part" --argjson names "$names" \
            '(.[] | select(.part == $part) | [.images[].image]) as $have | $names[] | select(("elysium-'"$service"'-" + .) as $i | $have | index($i) | not)' <<<"$parts")"
        [ -z "$missing" ] || fail "$compose: part $part lists $missing, which this file doesn't build"
    done < <(jq -r 'to_entries[] | [.key, .value.version, (.value.images | tojson)] | @tsv' <<<"$declared")

    # Every image of a service with parts belongs to exactly one of them
    if jq -e --arg s "$service" 'any(.[]; .service == $s)' <<<"$parts" >/dev/null; then
        while IFS= read -r image; do
            count="$(jq --arg i "$image" '[.[] | .images[] | select(.image == $i)] | length' <<<"$parts")"
            [ "$count" -eq 1 ] || fail "$compose: image $image is in $count release parts; it must be in exactly one"
        done < <(jq -r '.[].image' <<<"$mine")
        jq -e --arg s "$service" 'all(.[] | select(.service == $s); (.images | length) > 0)' <<<"$parts" >/dev/null ||
            fail "$compose: a release part lists no image this file builds"
    fi
done < <(find . -name docker-compose.yml -not -path '*/node_modules/*' -not -path './.claude/*' -not -path './.git/*' | sort)

dupes="$(jq -r 'group_by(.part)[] | select(length > 1) | .[0].part' <<<"$parts")"
[ -z "$dupes" ] || fail "Release part names must be unique: $dupes"
echo "$parts"
