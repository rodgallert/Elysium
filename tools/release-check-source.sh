#!/usr/bin/env bash
# Checks that the images docker-compose.prod.yml pins for a release part were built from the code being merged:
# every image of the part was built from one commit, and that commit's service folder and release tooling
# (.github/workflows/release.yml, .github/actions/release-image/, tools/) are identical to HEAD's. Any change
# there after the prepare run, CHANGELOG.md included, needs another prepare run. Prints the build commit.
#
#   release-check-source.sh [--attested <sbom dir>] <part> <version>
#
# Without --attested (pull requests): the build commit is the images' org.opencontainers.image.revision label,
# read from the registry. An early check that the release job repeats.
# With --attested (the release job): the build commit comes from the verified provenance certificate
# (sourceRepositoryDigest), which the build can't choose; the label must agree. Both attestations (provenance
# and SBOM) must be signed by this repository's release workflow on a GitHub-hosted runner, and the attested
# SBOMs are written to <sbom dir>.
# Needs GITHUB_REPOSITORY (owner/repo) and, with --attested, GH_TOKEN. RELEASE_REGISTRY overrides ghcr.io.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

sboms=""
if [ "${1:-}" = "--attested" ]; then sboms="${2:?--attested needs a directory}"; shift 2; fi
part="${1:?usage: release-check-source.sh [--attested <sbom dir>] <part> <version>}"
version="${2:?usage: release-check-source.sh [--attested <sbom dir>] <part> <version>}"
repository="${GITHUB_REPOSITORY:?}"
owner="${repository%%/*}"
registry="${RELEASE_REGISTRY:-ghcr.io}"
signer="$repository/.github/workflows/release.yml"
tooling=(.github/workflows/release.yml .github/actions/release-image tools)

fail() { echo "$part $version: $*" >&2; exit 1; }

info="$(tools/release-parts.sh | jq -c --arg p "$part" '.[] | select(.part == $p)')"
[ -n "$info" ] || fail "no such release part"
folder="$(jq -r .folder <<<"$info")"
pinned="$(docker compose -f docker-compose.prod.yml config --no-interpolate --format json | jq -r '.services // {} | .[].image // empty')"

built_from=""
while IFS= read -r image; do
    name="$registry/$owner/$image"
    line="$(grep -F "$name:$version@" <<<"$pinned" | head -1 || true)"
    [ -n "$line" ] || fail "docker-compose.prod.yml doesn't pin $image at $version with a digest; run the prepare run"
    digest="${line##*@}"

    label="$(docker buildx imagetools inspect "$name@$digest" --format '{{json .Image}}' 2>/dev/null |
        jq -r '.config.Labels["org.opencontainers.image.revision"] // empty' || true)"
    [ -n "$label" ] || fail "$image: $name@$digest can't be read, or has no revision label"
    commit="$label"

    if [ -n "$sboms" ]; then
        verify=(gh attestation verify "oci://$name@$digest" -R "$repository" --signer-workflow "$signer" --deny-self-hosted-runners --format json)
        provenance="$("${verify[@]}")" || fail "$image: no build provenance signed by $signer"
        commit="$(jq -r '.[0].verificationResult.signature.certificate.sourceRepositoryDigest // empty' <<<"$provenance")"
        [ -n "$commit" ] || fail "$image: the provenance certificate names no source commit"
        [ "$commit" = "$label" ] || fail "$image: built from $commit (certificate), but its revision label says $label"
        "${verify[@]}" --predicate-type https://spdx.dev/Document/v2.3 |
            jq '.[0].verificationResult.statement.predicate' >"$sboms/$image.spdx.json" ||
            fail "$image: no SBOM attestation signed by $signer"
    fi

    [ -z "$built_from" ] || [ "$built_from" = "$commit" ] || fail "the part's images were built from different commits"
    built_from="$commit"
done < <(jq -r '.images[].image' <<<"$info")

git cat-file -e "$built_from^{commit}" 2>/dev/null || git fetch -q --no-tags origin "$built_from" ||
    fail "can't fetch $built_from, the commit the images were built from"
for path in "$folder" "${tooling[@]}"; do
    if [ "$(git rev-parse "$built_from:$path" 2>/dev/null)" != "$(git rev-parse "HEAD:$path" 2>/dev/null)" ]; then
        fail "$path changed since the prepare run built the images (from $built_from); prepare again before the merge, or release a new version after it"
    fi
done
echo "$built_from"
