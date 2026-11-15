#!/usr/bin/env bash
# Prints whether a release part's version is already released: "released" or "unreleased".
#
#   released    the git tag <part>-v<version> exists, its GitHub Release exists, and every image of the part is
#               tagged <version> in the registry with the digest docker-compose.prod.yml pins (a hotfix's
#               version and pin copied back to main); and, because anyone with push access can create a tag, a
#               Release or an image tag, the images are proven to come from a real release:
#               - every pinned digest has provenance and SBOM attestations signed by this repository's release
#                 workflow, on a GitHub-hosted runner, for the commit the images were built from;
#               - that commit's service folder and release tooling equal the tagged commit's
#                 (tools/release-check-source.sh --attested --against);
#               - the tagged commit is on main or a release/** branch, which change only through reviewed PRs,
#                 and its version file says <version>
#   unreleased  none of these exist yet (an ordinary release PR)
#
# Anything else fails (exit 1): a lookup that errors (network, registry, API, permissions) instead of answering
# "not found", or a mixed state, such as a tag without a Release, an image tag without a git tag, or a released
# version whose image tag doesn't match the pin. A failed lookup is never read as "released" or "unreleased".
#
#   release-state.sh <part> <version>
# Needs GITHUB_REPOSITORY (owner/repo) and, for a released version, GH_TOKEN (attestations); GH_TOKEN is also used
# for the Releases API when set (public repositories answer without it). RELEASE_REGISTRY overrides ghcr.io, GITHUB_API_URL the API.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

part="${1:?usage: release-state.sh <part> <version>}"
version="${2:?usage: release-state.sh <part> <version>}"
repository="${GITHUB_REPOSITORY:?}"
owner="${repository%%/*}"
registry="${RELEASE_REGISTRY:-ghcr.io}"
api="${GITHUB_API_URL:-https://api.github.com}"
tag="$part-v$version"

fail() { echo "$part $version: $*" >&2; exit 1; }

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail "version is not x.y.z"
info="$(tools/release-parts.sh | jq -c --arg p "$part" '.[] | select(.part == $p)')"
[ -n "$info" ] || fail "no such release part"

# Git tag, by its exact name (tools/release-tag-commit.sh; ls-remote alone also matches x/refs/tags/<tag>)
tag_commit="$(tools/release-tag-commit.sh "$tag")" || fail "can't look up the git tag $tag"
if [ -n "$tag_commit" ]; then git_tag=yes; else git_tag=no; fi

# GitHub Release: 200 exists, 404 doesn't, anything else (including no answer) is an error
auth=()
[ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${auth[@]}" \
    -H "Accept: application/vnd.github+json" "$api/repos/$repository/releases/tags/$tag" || true)"
case "$status" in
    200) release=yes ;;
    404) release=no ;;
    *) fail "can't look up the GitHub Release $tag (HTTP ${status:-no answer})" ;;
esac

# The proof that a version which looks released came from a real release (see the header)
prove_released() {
    local tagged tips tip on_branch=no sboms
    # (exact ref names only: tools/release-tag-commit.sh)
    tagged="$(tools/release-tag-commit.sh "$tag")" || fail "can't look up the git tag $tag"
    [[ "$tagged" =~ ^[0-9a-f]{40}$ ]] || fail "can't resolve the git tag $tag to a commit"

    tips="$(git ls-remote --heads origin refs/heads/main 'refs/heads/release/*')" || fail "can't list main and the release branches"
    tips="$(awk '{ print $1 }' <<<"$tips")"
    [ -n "$tips" ] || fail "no main or release branch found"
    local missing=() commit
    for commit in "$tagged" $tips; do
        git cat-file -e "$commit^{commit}" 2>/dev/null || missing+=("$commit")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        git fetch -q --no-tags origin "${missing[@]}" || fail "can't fetch the tagged commit and the protected branches"
    fi
    for tip in $tips; do
        if git merge-base --is-ancestor "$tagged" "$tip"; then on_branch=yes; break; fi
    done
    [ "$on_branch" = yes ] || fail "tag $tag is on $tagged, which isn't on main or a release branch"

    # The tagged commit must itself carry this version, so a tag put on an older commit can't make that commit's
    # genuine build count as released under a version it never had
    local file tagged_version
    file="$(jq -r .versionFile <<<"$info")"
    tagged_version="$(tools/release-parts.sh version "$file" "$tagged")"
    [ "$tagged_version" = "$version" ] ||
        fail "tag $tag is on $tagged, whose $file says '${tagged_version:-no version}', not $version"

    sboms="$(mktemp -d)"
    tools/release-check-source.sh --attested "$sboms" --against "$tagged" "$part" "$version" >/dev/null ||
        { rm -rf "$sboms"; fail "its images can't be proven to come from the release of $tagged"; }
    rm -rf "$sboms"
}

# Image tags: a digest, "not found", or an error
pinned="$(docker compose -f docker-compose.prod.yml config --no-interpolate --format json | jq -r '.services // {} | .[].image // empty')"
images_tagged=0
images_total=0
mismatch=""
while IFS= read -r image; do
    images_total=$((images_total + 1))
    name="$registry/$owner/$image"
    if out="$(docker buildx imagetools inspect "$name:$version" --format '{{json .Manifest}}' 2>&1)"; then
        digest="$(jq -r '.digest // empty' <<<"$out" 2>/dev/null || true)"
        [ -n "$digest" ] || fail "can't read the digest of $name:$version"
        images_tagged=$((images_tagged + 1))
        pin="$(grep -F "$name:$version@" <<<"$pinned" | head -1 || true)"
        [ "${pin##*@}" = "$digest" ] || mismatch+=" $image"
    elif [ "$(tail -1 <<<"$out")" = "ERROR: $name:$version: not found" ]; then
        : # not tagged
    else
        fail "can't look up $name:$version: $(tail -1 <<<"$out")"
    fi
done < <(jq -r '.images[].image' <<<"$info")

if [ "$git_tag" = yes ] && [ "$release" = yes ] && [ "$images_tagged" -eq "$images_total" ]; then
    [ -z "$mismatch" ] || fail "is released, but docker-compose.prod.yml doesn't pin the released digest of:$mismatch"
    prove_released
    echo released
elif [ "$git_tag" = no ] && [ "$release" = no ] && [ "$images_tagged" -eq 0 ]; then
    echo unreleased
else
    fail "is partly released (git tag: $git_tag, GitHub Release: $release, image tags: $images_tagged of $images_total); finish or repair the release first"
fi
