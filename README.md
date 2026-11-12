# Autograder

Scores a lab repo against the **technical build** rubric (`rubrics/technical-build.md`) without deploying anything to AWS. Lucas then only reviews the reasoning (proposal) and the presentation.

## What it runs

| Step | Tool | Rubric category |
|---|---|---|
| Format | `terraform fmt -check` | iac-quality |
| Validate | `terraform init -backend=false && terraform validate` | iac-quality (gate: if this fails, every test counts as failed) |
| Lint | `tflint` | iac-quality |
| Plan-time tests | `terraform test` with `mock_provider "aws"`, **one check per file**, category from the `# rubric: <category>` header | per file |
| Policy as code | `conftest --parser hcl2 --combine --all-namespaces` — one Rego package per category (`resilience`, `observability`, `security`, `cost`, `iac_quality`, `academy`) | package name |
| Security scan | `checkov`, minus skips in `terraform/.checkov.yaml` (each skip needs a `# reason:`) | security |
| App tests | `python -I -m pytest tests/` (only the canonical test IDs count) | tests |
| Structure | no symlinks, `.tf.json`, `override.tf` / `*_override.tf`, modules (unless the case allows them) or `tflint-ignore` comments | iac-quality |

Score = Σ category weight × (passed / total). Weights default to `WEIGHTS` in `score.py` and are overridden per case by `policy/weights.json`, which puts most points on that week's new work. Categories with no checks are redistributed.

Output: `grade-report.md` (shown as the GitHub Actions job summary) and `grade-report.json`.

Case switches also live in `policy/weights.json`, as `_`-prefixed keys: `"_allow_local_modules": true` (week 12) lets `./modules/...` through and feeds the module files to conftest; `"_allow_remote_modules": true` allows registry/git modules.

Exit codes: `0` scored · `1` `--strict` and below 100 · `2` setup problem (missing tool, or the `--overlay` case folder doesn't exist) · `3` submission rejected (symbolic links; a score-0 report is still written) · `4` infrastructure failure (provider download, plugin cache, checksum): rerun, the team's code isn't at fault. Don't share one `TF_PLUGIN_CACHE_DIR` between grading runs that happen at the same time.

## How students get feedback

Each starter repo has `.github/workflows/grade.yml`, which calls the reusable workflow in the public `resilience-in-the-cloud/autograder` repo on every push. That workflow **overlays the canonical tests and policies** from `cases/<case>/` before scoring, so editing tests in a student repo doesn't change the grade.

## How Lucas grades

```bash
tools/sync-grader-cases.sh                                  # after changing any solution's tests
# Mon 11:59 p.m.: Classroom 50 -> the assignment -> Actions -> Close submission (repos go read-only)
autograder/grade-all.sh week-03-branch-locator closed       # grades each team's HEAD -> grades/<case>/scores.csv
# Missed closing on time? Run snapshot.sh at the deadline instead; grade-all then uses it.
autograder/snapshot.sh week-03-branch-locator
autograder/spot-check.sh /path/to/a/cloned/submission       # optional, week 1 only: live deploy + failure injection in Academy
```

`grades/` is git-ignored. Don't post scores anywhere public (FERPA).

**`grade-all.sh` is the official score.** The report in a team's Actions tab is feedback only, because a team can edit its own workflow file. `grade-all.sh` re-grades with the canonical tests here, and with `--require-tools`, so a missing tool stops the run instead of quietly re-weighting the score. A repo that can't be graded (clone failure, symlinks, infrastructure error) gets an `ERROR` row and the run moves on. A row whose note says `REVIEW` has code that could tamper with the test run; read it.

**Which commit counts: push time, not commit dates.** Teams control commit dates (`git commit --date`, `GIT_COMMITTER_DATE`), so "last commit before the deadline" can be gamed. The normal path: right after Monday 11:59 p.m., click **Close submission** for the assignment in Classroom 50 (classroom50.org). Every team repo becomes read-only, so HEAD is exactly what was pushed in time, and `grade-all.sh <case> closed` grades HEAD. Classroom 50 itself warns that the scores it collects can be forged and recommends close → download → run the tests yourself, which is what `grade-all.sh` does. If you miss the close, run `snapshot.sh <case>` at the deadline (by hand at 11:59 p.m., or `at`/cron). It records every team's pushed HEAD in `grades/<case>/snapshot.csv` within a minute or two, then saves a git bundle per repo so a later force-push can't erase it. `grade-all.sh` uses the snapshot when it exists. Without one, pass a deadline and it falls back to committer dates; every row then says `committer-date (team-controlled)` in the `method` column. The `note` column counts commits pushed after the graded one.

**It runs student code** (pytest and Terraform providers). Run it in a throwaway VM, container or Codespace that has no AWS keys and no broad GitHub token. The script refuses to start if `AWS_*` credentials are in the environment. `spot-check.sh` deploys student Terraform into a Learner Lab account with your credentials. It works on a copy with a forced local backend, lists any `local-exec`, `external` or remote module it finds and asks you to confirm, but you should still read the team's `.tf` files first.

### Isolation: what is and isn't protected

- pytest runs with `python -I`, so a `pytest.py` (or any module) in the repo can't replace the real one. A team `conftest.py`, `pytest.ini` and `requirements-dev.txt` are ignored.
- Only the canonical test IDs score, each exactly once. Extra passing results or duplicates mean something rewrote the results: the tests category scores 0 and the report says why.
- Symlinks anywhere in the repo stop grading before anything is copied, so the overlay can't write outside the repo.
- Each repo is scored against a fresh, read-only copy of `score.py` and the case, and its report goes to its own temp folder before it's copied to `grades/`.

**That is not real isolation.** The canonical tests import the team's app code, and it runs as you. A determined team can still forge its own pytest results in-process (for example from an `atexit` hook that writes the canonical test names), and in principle touch anything your user can, including other teams' reports. `score.py` flags the usual tools for this (`atexit`, `junit`, `sys.argv`, `_pytest`, `os._exit`) as `REVIEW`, but obfuscated code can slip past. For real isolation, score each repo in its own container, which `grade-all.sh` does when `GRADER_IMAGE` is set:

```bash
docker build -t itcs5010-grader autograder/            # same tool versions as the CI workflow
GRADER_IMAGE=itcs5010-grader autograder/grade-all.sh week-03-branch-locator
CONTAINER_ENGINE=podman GRADER_IMAGE=itcs5010-grader autograder/grade-all.sh week-03-branch-locator
```

Each container mounts only that team's clone, a read-only copy of the grader and an empty report folder, and gets no credentials. That protects the grader and other teams. It still can't stop a team from forging its *own* pytest results, so keep reading the `REVIEW` rows.

**What the grader ignores on purpose:**
- A team's own `.tflint.hcl` (the canonical `tflint.hcl` is used).
- Root-level `.checkov.yaml`.
- `conftest.py` and `pytest.ini`.
- `#checkov:skip` comments for checks the case doesn't allow.
- Inline `# tflint-ignore` comments (each one is a failed check).
- `requirements-dev.txt` in CI (only pinned `pytest` and `checkov` are installed).
- Resources declared with `count`/`for_each` don't satisfy "an X must exist" rules (a `count = 0` decoy creates nothing); the policies deny `count`/`for_each` on the types those rules check.

Extra Terraform tests a team writes are kept and listed in the report for you to read; only the canonical tests are scored. Team repos must be **private** (Classroom 50 default), because grade reports are uploaded as Actions artifacts.

## Adding a case

1. Build `solutions/week-NN-<slug>/` so `python3 autograder/score.py --repo solutions/week-NN-<slug>` = 100.
2. Strip the week's new resilience features from `labs/week-NN-<slug>/` and mark them `TODO(week N)`; it should still `validate`, and should score clearly lower.
3. `tools/sync-grader-cases.sh`, then `tools/test-labs.sh`. `publish-repos.sh` refuses to publish a starter whose case folder doesn't exist.

## Run locally

```bash
python3 autograder/score.py --repo labs/week-01-balance-lookup --out /tmp/report
# Tool paths can be overridden: TFLINT=… CONFTEST=… CHECKOV=… PYTHON=…
```

## Academy gate: reopen one team

After **Close submission**, every team repo is read-only. When a team asks to fix an `[academy]` finding, reopen only that team's repo for 48 hours. **Reopen submission** in Classroom 50 reopens the whole assignment, so don't use it here; change the one repo's team permission on GitHub instead:

```bash
ORG=resilience-in-the-cloud; REPO=<team repo from scores.csv>
gh api repos/$ORG/$REPO/teams --jq '.[] | "\(.slug) \(.permission)"'   # find the team slug and current permission
gh api -X PUT orgs/$ORG/teams/<team-slug>/repos/$ORG/$REPO -f permission=push   # reopen (write)
# ... 48 hours later:
gh api -X PUT orgs/$ORG/teams/<team-slug>/repos/$ORG/$REPO -f permission=pull   # read-only again
```

Then re-check **only the gate**: run `python3 autograder/score.py --repo <clone at new HEAD> --overlay autograder/cases/<case>` and confirm the `academy` category has no denies. If it's clean, lift the 20/40 cap in Canvas; every other category keeps its score from the commit in `scores.csv`. Note the reopen time and new sha in the Canvas comment.

VERIFY in a test classroom before January: that Classroom 50's Close submission is implemented as a team permission change (so the commands above undo it for one repo), and that it doesn't reset the permission on its next sync.
