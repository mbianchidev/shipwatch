#!/bin/bash
# Prints Markdown release notes: the pull requests merged and the commits made since the previous release.
# Usage: bash scripts/release-notes.sh <previous-tag or ""> <target-commit> <owner/repo> <new-tag>
set -euo pipefail

die() { echo "Release notes failed: $1" >&2; exit 1; }
[ "$#" -eq 4 ] || die "Usage: bash scripts/release-notes.sh <previous-tag or \"\"> <target-commit> <owner/repo> <new-tag>"
PREVIOUS="$1"
TARGET="$2"
REPO="$3"
TAG="$4"

git rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null || die "$TARGET is not a commit."
if [ -n "$PREVIOUS" ]; then
  git rev-parse --verify --quiet "refs/tags/$PREVIOUS^{commit}" >/dev/null \
    || die "Tag $PREVIOUS is missing; fetch the full history with tags."
  RANGE="$PREVIOUS..$TARGET"
else
  RANGE="$TARGET"
fi

PULLS=()
while read -r SHA; do
  SUBJECT="$(git show -s --format=%s "$SHA")"
  [[ "$SUBJECT" =~ ^Merge\ pull\ request\ \#([0-9]+)\  ]] || continue
  # GitHub puts the pull request title on the first line of the merge commit body.
  TITLE="$(git show -s --format=%b "$SHA" | sed -n '/[^[:space:]]/{p;q;}')"
  PULLS+=("- ${TITLE:-$SUBJECT} (#${BASH_REMATCH[1]})")
done < <(git log --merges --first-parent --reverse --format=%H "$RANGE")

COMMITS="$(git log --no-merges --reverse --format='- %s (%h)' "$RANGE")"

if [ "${#PULLS[@]}" -gt 0 ]; then
  printf '## Pull requests\n\n'
  printf '%s\n' "${PULLS[@]}"
  printf '\n'
fi
printf '## Commits\n\n'
if [ -n "$COMMITS" ]; then
  printf '%s\n' "$COMMITS"
else
  printf -- '- No changes since %s.\n' "$PREVIOUS"
fi
printf '\n'
if [ -n "$PREVIOUS" ]; then
  printf '**Full changelog**: https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREVIOUS" "$TAG"
else
  printf '**Full changelog**: https://github.com/%s/commits/%s\n' "$REPO" "$TAG"
fi
