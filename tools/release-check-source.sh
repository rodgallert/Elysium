#!/usr/bin/env bash
# Checks that the images docker-compose.prod.yml pins for a release part were built from the code being merged:
# every image of the part was built from one commit, and that commit's service folder and release tooling
# (.github/workflows/release.yml, .github/actions/release-image/, tools/) are identical to HEAD's. Any change
# there after the prepare run, CHANGELOG.md included, needs another prepare run. Prints the build commit.
#
#   release-check-source.sh [--attested <sbom dir>] [--against <commit>] <part> <version>
#
# --against compares with <commit> instead of HEAD (tools/release-state.sh: the commit a version tag points at).
#
# Without --attested (pull requests): the build commit is the images' org.opencontainers.image.revision label,
# read from the registry. An early check that the release job repeats.
# With --attested (the release job): the provenance and SBOM attestations must be signed by this repository's
# release workflow, on a GitHub-hosted runner, for that commit: the certificate's sourceRepositoryDigest, which
# the build can't choose, must equal the label (gh attestation verify --source-digest). The attested SBOMs are
# written to <sbom dir>.
# Needs GITHUB_REPOSITORY (owner/repo) and, with --attested, GH_TOKEN. RELEASE_REGISTRY overrides ghcr.io.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

usage="usage: release-check-source.sh [--attested <sbom dir>] [--against <commit>] <part> <version>"
sboms=""
against=HEAD
while [ $# -gt 0 ]; do
    case "$1" in
        --attested) sboms="${2:?$usage}"; shift 2 ;;
        --against) against="${2:?$usage}"; shift 2 ;;
        *) break ;;
    esac
done
part="${1:?$usage}"
version="${2:?$usage}"
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
    # A full commit id, before any git command or flag sees it
    [[ "$label" =~ ^[0-9a-f]{40}$ ]] || fail "$image: revision label '$label' is not a full commit id"
    commit="$label"

    if [ -n "$sboms" ]; then
        # --source-digest: only attestations whose certificate names this commit count, so an attestation of the
        # same digest from another run (another branch, another commit) can't be the one picked
        verify=(gh attestation verify "oci://$name@$digest" -R "$repository" --signer-workflow "$signer"
            --source-digest "$commit" --deny-self-hosted-runners --format json)
        "${verify[@]}" >/dev/null || fail "$image: no build provenance signed by $signer for commit $commit"
        "${verify[@]}" --predicate-type https://spdx.dev/Document/v2.3 |
            jq '.[0].verificationResult.statement.predicate' >"$sboms/$image.spdx.json" ||
            fail "$image: no SBOM attestation signed by $signer"
    fi

    [ -z "$built_from" ] || [ "$built_from" = "$commit" ] || fail "the part's images were built from different commits"
    built_from="$commit"
done < <(jq -r '.images[].image' <<<"$info")

git cat-file -e "$built_from^{commit}" 2>/dev/null || git fetch -q --no-tags origin "$built_from" ||
    fail "can't fetch $built_from, the commit the images were built from"
git cat-file -e "$against^{commit}" 2>/dev/null || fail "$against is not a commit here"
for path in "$folder" "${tooling[@]}"; do
    # --verify -q prints nothing for a path a commit doesn't have (plain rev-parse would echo the argument)
    if [ "$(git rev-parse --verify -q "$built_from:$path")" != "$(git rev-parse --verify -q "$against:$path")" ]; then
        fail "$path differs between $built_from, the commit the images were built from, and $against; prepare again before the merge, or release a new version after it"
    fi
done
echo "$built_from"
