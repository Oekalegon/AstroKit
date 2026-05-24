#!/usr/bin/env bash
# Finishes the current git flow release branch using the version from version.txt.
# Usage: bash scripts/release-finish.sh
#
# Equivalent to: git flow release finish <version> -m "<version>"
# The tag message defaults to the version string; pass an argument to override it.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
VERSION="$(cat "$REPO_ROOT/version.txt" | tr -d '[:space:]')"
TAG_MSG="${1:-$VERSION}"

echo "  Finishing release $VERSION (tag: $VERSION, message: \"$TAG_MSG\")"
git flow release finish "$VERSION" -m "$TAG_MSG"
