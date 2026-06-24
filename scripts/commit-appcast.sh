#!/usr/bin/env bash
# Commit the regenerated appcast to a branch via the GitHub contents API.
#
# Uses the API (not `git push`) on purpose: it produces a GitHub-signed,
# "verified" commit, which the protected default branch requires. $GH_TOKEN
# must be allowed to bypass that branch's protection (an admin / bypass PAT).
#
# Usage: commit-appcast.sh <local-appcast> <owner/repo> <branch> <tag>
set -euo pipefail

LOCAL="${1:?local appcast path required}"
REPO="${2:?owner/repo required}"
BRANCH="${3:?branch required}"
TAG="${4:?tag required}"
: "${GH_TOKEN:?GH_TOKEN required}"

[[ -f "$LOCAL" ]] || {
  echo "error: appcast not found: $LOCAL" >&2
  exit 1
}

REMOTE_PATH="site/appcast.xml"
content="$(base64 <"$LOCAL" | tr -d '\n')"
# Current blob sha so the API does an update; empty (omitted) creates the file.
sha="$(gh api "repos/$REPO/contents/$REMOTE_PATH?ref=$BRANCH" --jq '.sha' 2>/dev/null || true)"

gh api -X PUT "repos/$REPO/contents/$REMOTE_PATH" \
  -f message="Publish appcast for $TAG" \
  -f content="$content" \
  -f branch="$BRANCH" \
  ${sha:+-f sha="$sha"}

echo "committed $REMOTE_PATH to $BRANCH ($TAG)"
