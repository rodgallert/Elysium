#!/usr/bin/env bash
# Fails when a project breaks the service boundaries:
# - a ProjectReference that leaves its service (the top-level folder it lives in, e.g. Prince/ or Masquerade/),
#   because services only talk through APIs and messages;
# - a *.Domain project with any package or project reference, because the domain depends on nothing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
status=0

while IFS= read -r -d '' proj; do
    rel="${proj#"$root"/}"
    service="${rel%%/*}"
    dir="$(dirname "$proj")"

    # Project references, with Windows separators normalised
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        target="$(realpath -m "$dir/${ref//\\//}")"
        target_rel="${target#"$root"/}"
        if [ "${target_rel%%/*}" != "$service" ]; then
            echo "$rel: references $target_rel, outside the $service service"
            status=1
        fi
    done < <(grep -oP '<ProjectReference\s+Include="\K[^"]+' "$proj" || true)

    if [[ "$(basename "$proj")" == *.Domain.csproj ]] && grep -qE '<(PackageReference|ProjectReference)\s' "$proj"; then
        echo "$rel: a Domain project must not reference any package or project"
        status=1
    fi
done < <(find "$root" -name '*.csproj' -not -path '*/bin/*' -not -path '*/obj/*' -print0)

[ "$status" -eq 0 ] && echo "Service boundaries OK"
exit "$status"
