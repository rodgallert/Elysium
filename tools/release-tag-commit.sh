#!/usr/bin/env bash
# Prints the commit a git tag on origin points at: the peeled (^{}) line of an annotated tag, else the line of a
# lightweight one; prints nothing when the tag doesn't exist. Fails when the lookup itself fails.
#
# git ls-remote matches a pattern against the end of a ref name, so a decoy tag such as x/refs/tags/<tag> also
# answers a lookup of <tag>. Only the lines whose name is exactly refs/tags/<tag> or refs/tags/<tag>^{} count.
#
#   release-tag-commit.sh <tag>
set -euo pipefail

tag="${1:?usage: release-tag-commit.sh <tag>}"
refs="$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"
TAG="$tag" awk '
    $2 == "refs/tags/" ENVIRON["TAG"] "^{}" { peeled = $1 }
    $2 == "refs/tags/" ENVIRON["TAG"] { plain = $1 }
    END { print (peeled != "" ? peeled : plain) }
' <<<"$refs"
