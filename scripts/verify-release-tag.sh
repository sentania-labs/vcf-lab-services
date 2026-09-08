#!/bin/bash
set -euo pipefail

# Release tag gate. A tag may only become a release when it is shaped like
# vMAJOR.MINOR.PATCH and its commit is already on the mainline branch, so a
# tag pushed from a stray branch never builds a release.
tag="${1:?usage: verify-release-tag.sh TAG [MAINLINE_REF]}"
mainline="${2:-origin/main}"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo "ERROR: release tag '$tag' must match vMAJOR.MINOR.PATCH" >&2
	exit 2
}

tag_commit="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || {
	echo "ERROR: tag $tag does not exist in this checkout" >&2
	exit 2
}
mainline_commit="$(git rev-parse --verify --quiet "$mainline^{commit}")" || {
	echo "ERROR: mainline ref '$mainline' does not exist in this checkout" >&2
	exit 2
}

if ! git merge-base --is-ancestor "$tag_commit" "$mainline_commit"; then
	echo "ERROR: tag $tag points at $tag_commit, which is not reachable from $mainline." >&2
	echo "       Merge the change to main first, then tag the merged commit." >&2
	exit 1
fi

echo "Release tag $tag is well formed and its commit $tag_commit is on $mainline"
