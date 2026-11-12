#!/usr/bin/env bash
# Instructor batch grading: clone every team repo for an assignment from the
# course org, score the commit that was on GitHub at the deadline with the canonical
# tests, and write a CSV for Canvas. THIS is the official technical-build score
# (rubrics/technical-build.md); the Actions report in a team's repo is feedback only.
#
# Usage: autograder/grade-all.sh <case> closed|<deadline> [repo-prefix]
#   e.g. autograder/grade-all.sh week-03-branch-locator closed
# Which commit is graded:
#   1. `closed`: you clicked Classroom 50's "Close submission" right after the deadline, so
#      every team repo is read-only and HEAD is what was pushed in time. The normal path.
#   2. grades/<case>/snapshot.csv from autograder/snapshot.sh, run AT the deadline (the
#      fallback if submissions weren't closed on time; used whenever it exists).
#   3. Otherwise the last commit whose COMMITTER DATE is before <deadline>. Teams control that
#      date (git commit --date / GIT_COMMITTER_DATE), so every row says so in the method column.
# Repos are matched by name prefix. Name each Classroom 50 assignment after its
# template repo (lab-NN-<slug>, or balance-lookup-demo for week 1); Classroom 50
# then names team repos <assignment>-<team>.
# Output: grades/<case>/{scores.csv, <repo>.md, <repo>.json}  (git-ignored; FERPA: keep private)
# A repo that can't be graded gets an ERROR row (score blank) and the run continues.
#
# SECURITY: this runs student code (pytest, terraform providers). Run it in a throwaway
# VM/container or a Codespace with no AWS credentials in the environment, not on a laptop
# that holds your AWS keys or a GitHub token with org-admin scope beyond what cloning needs.
# Each repo is scored against a fresh read-only copy of score.py and the case, and its
# report is written to its own temp dir before it is copied to grades/. That stops a team's
# code from casually rewriting the grader or other teams' results, but it runs as you, so it
# is not real isolation. For that, set GRADER_IMAGE (see README.md, "Isolation") to score
# each repo in its own container.
set -euo pipefail
CASE="${1:?case name, e.g. week-01-balance-lookup}"
DEADLINE="${2:-}"
if [ "$CASE" = week-01-balance-lookup ]; then DEFAULT_PREFIX=balance-lookup-demo-; else DEFAULT_PREFIX="lab-${CASE#week-}-"; fi
PREFIX="${3:-$DEFAULT_PREFIX}"
ORG="${ORG:-resilience-in-the-cloud}"
HERE="$(cd "$(dirname "$0")" && pwd)"            # works in course-dev and in the standalone autograder repo
PY="${PYTHON:-python3}"
ENGINE="${CONTAINER_ENGINE:-docker}"
OUT="${OUT_DIR:-$PWD/grades/$CASE}"; WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
SNAP="$OUT/snapshot.csv"
[ -d "$HERE/cases/$CASE" ] || { echo "no canonical case at $HERE/cases/$CASE" >&2; exit 1; }
if [ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SESSION_TOKEN:-}${AWS_PROFILE:-}" ]; then
  echo "Refusing to run student code with AWS credentials in the environment. unset AWS_* first." >&2; exit 1
fi
if [ ! -f "$SNAP" ] && [ -z "$DEADLINE" ]; then
  echo "Say 'closed' (submissions closed in Classroom 50) or give a deadline; no $SNAP either." >&2; exit 1
fi
if [ -f "$SNAP" ]; then echo "Using deadline snapshot $SNAP"
elif [ "$DEADLINE" = closed ]; then echo "Submissions closed in Classroom 50: grading each repo's HEAD."
else echo "WARNING: submissions not closed and no snapshot.csv; falling back to committer dates, which teams control. See README.md." >&2
fi

csv(){ printf '%s\n' "$*" >> "$OUT/scores.csv"; }
mkdir -p "$OUT"; echo "repo,score,academy_gate,commit,commit_time,method,note" > "$OUT/scores.csv"

grader_copy(){ # fresh, read-only copy of the grader for one repo
  local g; g="$(mktemp -d "$WORK/grader.XXXXXX")"
  cp "$HERE/score.py" "$HERE/tflint.hcl" "$g/"
  mkdir -p "$g/cases"; cp -R "$HERE/cases/$CASE" "$g/cases/$CASE"
  chmod -R a-w "$g"
  echo "$g"
}

score_repo(){ # score_repo <repo-dir> <grader-dir> <report-dir>; prints score.py's exit code
  local repo="$1" g="$2" rd="$3" rc=0
  if [ -n "${GRADER_IMAGE:-}" ]; then
    "$ENGINE" run --rm --pull=never --cap-drop=ALL --security-opt no-new-privileges \
      --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -v "$repo:/work/repo" -v "$g:/grader:ro" -v "$rd:/work/out" "$GRADER_IMAGE" \
      python3 /grader/score.py --repo /work/repo --overlay "/grader/cases/$CASE" --require-tools \
      --out /work/out/report >/dev/null 2>"$rd.err" || rc=$?
  else
    "$PY" "$g/score.py" --repo "$repo" --overlay "$g/cases/$CASE" --require-tools \
      --out "$rd/report" >/dev/null 2>"$rd.err" || rc=$?
  fi
  echo "$rc"
}

for repo in $(gh repo list "$ORG" --limit 500 --json name --jq ".[] | select(.name | startswith(\"$PREFIX\")) | .name"); do
  [ "$repo" = "${PREFIX%-}" ] && continue   # skip the template itself
  dir="$WORK/$repo"
  if ! gh repo clone "$ORG/$repo" "$dir" -- --quiet; then
    csv "$repo,,ERROR,,,,clone failed"; echo "$repo  ERROR (clone failed)"; continue
  fi
  method="" sha=""
  if [ -f "$SNAP" ]; then
    method=snapshot
    sha=$(awk -F, -v r="$repo" '$1==r {print $2}' "$SNAP")
    if [ -n "$sha" ] && ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
      # Force-pushed away after the deadline: use the bundle snapshot.sh saved.
      b="$OUT/snapshot/$repo.bundle"
      [ -f "$b" ] && git -C "$dir" fetch -q "$b" "+refs/*:refs/snapshot/*" 2>/dev/null || true
    fi
  elif [ "$DEADLINE" = closed ]; then
    method="closed (HEAD)"
    sha=$(git -C "$dir" rev-parse -q --verify HEAD || true)
  else
    method="committer-date (team-controlled)"
    sha=$(git -C "$dir" rev-list -1 --before="$DEADLINE" HEAD || true)
  fi
  if [ -z "$sha" ]; then csv "$repo,0,fail,,,$method,no commit at the deadline"; echo "$repo  (no commit at the deadline)"; continue; fi
  if ! git -C "$dir" -c advice.detachedHead=false checkout -q "$sha" 2>/dev/null; then
    csv "$repo,,ERROR,${sha:0:7},,$method,snapshot commit not found"; echo "$repo  ERROR (commit $sha not found)"; continue
  fi
  note=""
  later=$(git -C "$dir" rev-list --count "$sha..origin/HEAD" 2>/dev/null || echo 0)
  [ "$later" -gt 0 ] && note="$later later commit(s) ignored"
  when=$(git -C "$dir" log -1 --format=%cI)
  g="$(grader_copy)"; rd="$(mktemp -d "$WORK/report.XXXXXX")"
  rc=$(score_repo "$dir" "$g" "$rd")
  case "$rc" in
    0) ;;
    2) echo "score.py setup error for $repo (missing tools?): $(tail -3 "$rd.err")" >&2
       echo "Install terraform, tflint, conftest, checkov, pytest (or fix GRADER_IMAGE) and re-run." >&2; exit 1 ;;
    3) cp "$rd/report.md" "$OUT/$repo.md" 2>/dev/null || true
       csv "$repo,,ERROR,${sha:0:7},$when,$method,REJECTED: $(tail -1 "$rd.err" | tr ',' ' ')"; echo "$repo  ERROR (rejected, see $repo.md)"; continue ;;
    4) csv "$repo,,ERROR,${sha:0:7},$when,$method,infrastructure error - re-run"; echo "$repo  ERROR (infrastructure, re-run)"; continue ;;
    *) csv "$repo,,ERROR,${sha:0:7},$when,$method,score.py exit $rc"; echo "$repo  ERROR (score.py exit $rc)"; continue ;;
  esac
  cp "$rd/report.md" "$OUT/$repo.md"; cp "$rd/report.json" "$OUT/$repo.json"
  read -r score gate flags < <("$PY" -I -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['score'],d['academy_gate'],len(d.get('review_flags',[])))" "$OUT/$repo.json")
  [ "$flags" -gt 0 ] && note="${note:+$note; }REVIEW: suspicious code (see $repo.md)"
  csv "$repo,$score,$gate,${sha:0:7},$when,$method,$note"; echo "$repo  $score  academy=$gate${note:+  ($note)}"
done
echo "Wrote $OUT/scores.csv"
