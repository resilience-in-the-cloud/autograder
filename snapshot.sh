#!/usr/bin/env bash
# Record what every team had PUSHED at the deadline, so grade-all.sh grades by push
# time instead of commit dates (which a team can set to anything).
#
# Run it AT the deadline (cron, `at`, or by hand right after 11:59 p.m.):
#   autograder/snapshot.sh week-03-branch-locator [repo-prefix]
#   echo 'cd ~/course-dev && autograder/snapshot.sh week-03-branch-locator' | at 23:59 Feb 1
#
# Writes grades/<case>/snapshot.csv (repo,sha,taken_at) first: one quick API call per
# repo, so every head is read within a minute or two. Then it saves a git bundle per repo
# in grades/<case>/snapshot/, so a force-push after the deadline can't erase the graded
# commit. grade-all.sh uses both automatically. Clones only; it runs no student code.
set -euo pipefail
CASE="${1:?case name, e.g. week-03-branch-locator}"
if [ "$CASE" = week-01-balance-lookup ]; then DEFAULT_PREFIX=balance-lookup-demo-; else DEFAULT_PREFIX="lab-${CASE#week-}-"; fi
PREFIX="${2:-$DEFAULT_PREFIX}"
ORG="${ORG:-resilience-in-the-cloud}"
OUT="${OUT_DIR:-$PWD/grades/$CASE}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/snapshot"
SNAP="$OUT/snapshot.csv"
[ -f "$SNAP" ] && { echo "$SNAP exists; move it away first so a snapshot is never overwritten." >&2; exit 1; }

repos=$(gh repo list "$ORG" --limit 500 --json name --jq ".[] | select(.name | startswith(\"$PREFIX\")) | .name")
echo "repo,sha,taken_at" > "$SNAP.tmp"
for repo in $repos; do
  [ "$repo" = "${PREFIX%-}" ] && continue   # the template itself
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch 2>/dev/null || echo main)
  sha=$(gh api "repos/$ORG/$repo/commits/$branch" --jq .sha 2>/dev/null || true)
  echo "$repo,$sha,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$SNAP.tmp"
  echo "$repo  ${sha:-NO COMMITS}"
done
mv "$SNAP.tmp" "$SNAP"
echo "Wrote $SNAP"

# Keep the objects too (slower; the heads above are already fixed).
tail -n +2 "$SNAP" | while IFS=, read -r repo sha _; do
  [ -n "$sha" ] || continue
  if gh repo clone "$ORG/$repo" "$WORK/$repo" -- --quiet --mirror 2>/dev/null; then
    git -C "$WORK/$repo" bundle create -q "$OUT/snapshot/$repo.bundle" --all 2>/dev/null \
      || echo "  ! bundle failed for $repo" >&2
    rm -rf "${WORK:?}/$repo"
  else
    echo "  ! clone failed for $repo (the sha is recorded; grade soon)" >&2
  fi
done
echo "Bundles in $OUT/snapshot/"
