#!/usr/bin/env bash
# Writes released images into docker-compose.prod.yml: every "image:" line of the given images becomes
# ghcr.io/<owner>/<image>:<version>@<digest>. The service's blocks must already be in the file (the release PR
# adds them for a service's first release, with the tag only); this only fills in tag and digest.
#
#   release-pin.sh [--file <compose file>] [--owner <owner>] <version> <image>=<sha256:digest> ...
#
# Fails, leaving the file as it was, when an image has no "image:" line in the file. That every image of a
# release part moves to the part's version together is checked afterwards by tools/check-prod-pins.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
file="$root/docker-compose.prod.yml"
owner="rodgallert"
while [ $# -gt 0 ]; do
    case "$1" in
        --file) file="$2"; shift 2 ;;
        --owner) owner="$2"; shift 2 ;;
        *) break ;;
    esac
done
version="${1:?usage: release-pin.sh [--file f] [--owner o] <version> <image>=<digest> ...}"
shift
[ $# -gt 0 ] || { echo "No images given" >&2; exit 1; }

# Work on a copy, so a failed run leaves the file as it was
work="$(mktemp)"
trap 'rm -f "$work"' EXIT
cp "$file" "$work"

status=0
for pair in "$@"; do
    image="${pair%%=*}"
    digest="${pair#*=}"
    if ! [[ "$image" =~ ^elysium-[a-z0-9]+(-[a-z0-9]+)+$ && "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "Not <image>=sha256:<digest>: $pair" >&2
        exit 1
    fi
    ref="ghcr.io/$owner/$image"
    # The image name, then an optional tag and digest, up to the end of the line or a comment
    pattern="^([[:space:]]*image:[[:space:]]*[\"']?)${ref//./\\.}(:[^@[:space:]\"']*)?(@sha256:[0-9a-f]*)?([\"']?[[:space:]]*(#.*)?)$"
    if ! grep -qE "$pattern" "$work"; then
        echo "$file has no 'image: $ref' line; add the service's blocks in the release PR" >&2
        status=1
        continue
    fi
    sed -i -E "s|$pattern|\\1$ref:$version@$digest\\4|" "$work"
done

[ "$status" -eq 0 ] || exit "$status"
cat "$work" >"$file"
