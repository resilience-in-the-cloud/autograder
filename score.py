#!/usr/bin/env python3
"""ITCS 5010 autograder: score one lab repo against the technical-build rubric.

Runs, from the repo root (no AWS credentials needed):
  terraform fmt / init -backend=false / validate     -> [iac-quality]
  tflint                                             -> [iac-quality]
  terraform test, one file per check                 -> category from "# rubric: X" header
  conftest (one Rego package per category)           -> that category
  checkov (minus terraform/.checkov.yaml skips)      -> [security]
  pytest tests/                                      -> [tests]

Writes grade-report.md (human, mapped to rubrics/technical-build.md) and
grade-report.json (machine). Exit code is always 0 unless --strict, so the
student sees a report instead of a red X they can't interpret.

Usage:
  python3 score.py [--repo PATH] [--overlay CASE_DIR] [--out PATH] [--strict]

--overlay copies the canonical terraform/tests, policy/, tests/ and .checkov.yaml
from autograder/cases/<case>/ over the student's copies first, and only the
canonical test files are scored, so weakening or adding tests in your repo
doesn't change your grade. Test files your team added are kept and listed in
the report for the instructor.

--require-tools exits 2 if any tool is missing instead of re-weighting the
score (grade-all.sh and test-labs.sh use it so instructor scores match CI).

Exit codes: 0 scored; 1 --strict and score < 100; 2 setup problem (missing tool,
missing --overlay case dir); 3 submission rejected (symbolic links; a report is
still written with score 0); 4 infrastructure error (provider download, plugin
cache, checksum), so the score would be meaningless: re-run it.

SECURITY: pytest imports the team's app code, so a determined team can tamper with
its own pytest results in-process. The grader runs pytest isolated (python -I), scores
only the canonical test IDs (extra or duplicate results zero the tests category) and
flags suspicious code for review, but true isolation needs one container per repo
(see README.md).

Stdlib only. Tools are looked up on PATH; override with env TERRAFORM, TFLINT,
CONFTEST, CHECKOV, PYTHON.
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Technical-build rubric weights (points out of 100). Keep in sync with
# rubrics/technical-build.md. Categories with no checks in a case have their
# weight redistributed proportionally.
WEIGHTS = {
    "resilience": 30,
    "observability": 20,
    "iac-quality": 15,
    "tests": 15,
    "security": 10,
    "cost": 5,
    "academy": 5,
}
NAMESPACE_TO_CATEGORY = {"iac_quality": "iac-quality"}

TOOL = {
    "terraform": os.environ.get("TERRAFORM", "terraform"),
    "tflint": os.environ.get("TFLINT", "tflint"),
    "conftest": os.environ.get("CONFTEST", "conftest"),
    "checkov": os.environ.get("CHECKOV", "checkov"),
    "python": os.environ.get("PYTHON", sys.executable),
}
HERE = Path(__file__).resolve().parent
TFLINT_CONFIG = HERE / "tflint.hcl"

# Output that means the toolchain failed, not the team's code (exit 4, re-run).
INFRA_PATTERNS = [
    "Failed to load plugin schemas", "does not match any of the checksums",
    "Failed to query available provider packages", "Failed to install provider",
    "could not connect to registry", "TLS handshake timeout",
    "i/o timeout", "connection reset by peer", "no such host",
]
# Code a team should never need in app code; seeing it means a human should look.
REVIEW_PATTERNS = re.compile(r"\batexit\b|junit|\b_pytest\b|os\._exit|\bpytest_[a-z_]+\s*\(|sys\.argv")


class InfraError(RuntimeError):
    """The toolchain failed (network, provider cache), so no fair score exists."""


def infra_check(text: str, step: str):
    hit = next((p for p in INFRA_PATTERNS if p in text), None)
    if hit:
        raise InfraError(f"{step}: {hit}\n{text[-1500:]}")


@dataclass
class Check:
    category: str
    name: str
    passed: bool
    detail: str = ""
    source: str = ""


@dataclass
class Report:
    repo: str
    checks: list[Check] = field(default_factory=list)
    skipped_tools: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    canonical_tftests: set[str] | None = None  # set by overlay(): only these files are scored
    canonical_pytests: dict | None = None  # set by overlay(): {(classname, func): expected count or None}
    zero_categories: set[str] = field(default_factory=set)  # tamper found: category scores 0
    review_flags: list[str] = field(default_factory=list)  # for the instructor, not scored
    options: dict = field(default_factory=dict)  # "_"-prefixed keys from policy/weights.json

    def add(self, category, name, passed, detail="", source=""):
        self.checks.append(Check(category, name, bool(passed), detail.strip()[:2000], source))


def run(cmd, cwd, timeout=600):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "TF_IN_AUTOMATION": "1", "NO_COLOR": "1",
                                "PYTHONDONTWRITEBYTECODE": "1"})
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def have(tool):
    return shutil.which(TOOL[tool]) is not None or Path(TOOL[tool]).exists()


def find_symlinks(repo: Path) -> list[str]:
    """Symlinks would let the overlay write outside the repo (or crash it), so they are refused."""
    found = []
    for root, dirs, files in os.walk(repo, followlinks=False):
        for n in dirs + files:
            p = Path(root) / n
            if p.is_symlink():
                found.append(str(p.relative_to(repo)))
        # Git internals and Terraform's provider cache may hold links; the grader writes to neither.
        dirs[:] = [d for d in dirs if d not in (".git", ".terraform") and not (Path(root) / d).is_symlink()]
    return sorted(found)


def safe_copy(src: Path, dst: Path):
    if dst.is_symlink() or dst.is_file():
        dst.unlink()
    shutil.copy(src, dst)


def canonical_pytest_ids(tests_dir: Path) -> dict:
    """{(junit classname, test function): number of parametrized cases, or None if unknown}.

    Read with ast from the canonical files, so no team code runs to produce it."""
    out = {}

    def cases(fn):
        n = 1
        for d in fn.decorator_list:
            if (isinstance(d, ast.Call) and isinstance(d.func, ast.Attribute) and d.func.attr == "parametrize"
                    and len(d.args) >= 2):
                if not isinstance(d.args[1], (ast.List, ast.Tuple)):
                    return None
                n *= len(d.args[1].elts)
        return n

    for f in sorted(tests_dir.glob("test_*.py")):
        mod = f"{tests_dir.name}.{f.stem}"
        for node in ast.parse(f.read_text(errors="replace")).body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test"):
                out[(mod, node.name)] = cases(node)
            elif isinstance(node, ast.ClassDef) and node.name.startswith("Test"):
                for m in node.body:
                    if isinstance(m, (ast.FunctionDef, ast.AsyncFunctionDef)) and m.name.startswith("test"):
                        out[(f"{mod}.{node.name}", m.name)] = cases(m)
    return out


def overlay(case_dir: Path, repo: Path, report: Report):
    # Terraform tests: copy canonical files in (replacing same-named ones) but keep extra team tests.
    src = case_dir / "terraform/tests"
    if src.is_dir():
        dst = repo / "terraform/tests"
        dst.mkdir(parents=True, exist_ok=True)
        canon = {f.name for f in src.glob("*.tftest.hcl")}
        for f in src.iterdir():
            safe_copy(f, dst / f.name)
        report.canonical_tftests = canon
        extra = sorted(f.name for f in dst.glob("*.tftest.hcl") if f.name not in canon)
        if extra:
            report.notes.append("Team-written Terraform tests (not auto-scored; the instructor reviews them): "
                                + ", ".join(extra))
    # Policies and app tests: replaced wholesale.
    for rel in ["policy", "tests"]:
        src = case_dir / rel
        if src.is_dir():
            dst = repo / rel
            if dst.is_symlink() or dst.is_file():
                dst.unlink()
            elif dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", ".pytest_cache"))
    if (case_dir / "tests").is_dir():
        report.canonical_pytests = canonical_pytest_ids(case_dir / "tests")
    ck = case_dir / "terraform/.checkov.yaml"
    if ck.exists():
        safe_copy(ck, repo / "terraform/.checkov.yaml")
    report.notes.append(f"Canonical tests/policies applied from {case_dir.name}.")


def load_options(repo: Path, report: Report):
    """Case switches are "_"-prefixed keys in policy/weights.json (the canonical copy after --overlay)."""
    try:
        data = json.loads((repo / "policy" / "weights.json").read_text())
        report.options = {k: v for k, v in data.items() if k.startswith("_")}
    except (OSError, json.JSONDecodeError, AttributeError):
        report.options = {}


def tf_files(tf: Path, recursive: bool) -> list[Path]:
    files = tf.rglob("*.tf") if recursive else tf.glob("*.tf")
    return sorted(p for p in files if ".terraform" not in p.relative_to(tf).parts)


def module_blocks(text: str):
    """Yield (name, source) for each module block (brace-matched; good enough for HCL)."""
    for m in re.finditer(r'^\s*module\s+"([^"]+)"\s*\{', text, re.M):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        s = re.search(r'^\s*source\s*=\s*"([^"]*)"', text[m.end():i], re.M)
        yield m.group(1), (s.group(1) if s else "?")


def check_structure(repo: Path, report: Report):
    """Code the policy and security scanners can't see must not hide resources from them."""
    tf = repo / "terraform"
    if not tf.is_dir():
        return
    hidden = sorted(str(p.relative_to(tf)) for p in tf.rglob("*.tf.json")
                    if ".terraform" not in p.relative_to(tf).parts)
    if hidden:
        report.add("iac-quality", "no .tf.json files (write HCL so policies can read it)", False,
                   "Found: " + ", ".join(hidden), "structure")
    overrides = sorted(str(p.relative_to(tf)) for p in tf_files(tf, True)
                       if p.name == "override.tf" or p.name.endswith("_override.tf"))
    if overrides:
        report.add("iac-quality", "no override files (they change values the policies read)", False,
                   "Found: " + ", ".join(overrides), "structure")
    # Modules only when the case asks for them ("_allow_local_modules" / "_allow_remote_modules"
    # in policy/weights.json): conftest can't read a registry or git module's resources at all.
    allow_local = bool(report.options.get("_allow_local_modules"))
    allow_remote = bool(report.options.get("_allow_remote_modules"))
    bad = []
    for f in tf_files(tf, allow_local):
        for name, src in module_blocks(f.read_text(errors="replace")):
            if (allow_local if src.startswith(("./", "../")) else allow_remote):
                continue
            bad.append(f'{f.relative_to(tf)}: module "{name}" (source = "{src}")')
    if bad:
        what = "remote modules" if allow_local else "modules"
        report.add("iac-quality", f"no {what} unless the case asks for them", False,
                   "\n".join(bad[:10]) + "\nThe policy and security checks can't see inside them.", "structure")


# --------------------------------------------------------------------------- checks

def check_terraform(repo: Path, report: Report) -> bool:
    tf = repo / "terraform"
    if not tf.is_dir():
        report.add("iac-quality", "terraform/ directory exists", False, "No terraform/ folder.")
        return False
    if not have("terraform"):
        report.skipped_tools.append("terraform")
        return False

    rc, out, err = run([TOOL["terraform"], "fmt", "-check", "-recursive", "-diff"], tf)
    report.add("iac-quality", "terraform fmt", rc == 0,
               "" if rc == 0 else "Run `terraform fmt -recursive`.\n" + out[-1500:], "terraform fmt")

    rc, out, err = run([TOOL["terraform"], "init", "-backend=false", "-input=false"], tf)
    if rc != 0:
        infra_check(out + err, "terraform init")
        report.add("iac-quality", "terraform init", False, err[-1500:], "terraform init")
        return False

    rc, out, err = run([TOOL["terraform"], "validate", "-no-color"], tf)
    if rc != 0:
        infra_check(out + err, "terraform validate")
    report.add("iac-quality", "terraform validate", rc == 0, (out + err)[-1500:] if rc else "", "terraform validate")
    return rc == 0


def check_tflint(repo: Path, report: Report):
    if not have("tflint"):
        report.skipped_tools.append("tflint")
        return
    tf = repo / "terraform"
    cfg = ["--config", str(TFLINT_CONFIG)] if TFLINT_CONFIG.exists() else []
    run([TOOL["tflint"], "--init", *cfg], tf)
    rc, out, err = run([TOOL["tflint"], *cfg, "--format=compact", "--no-color"], tf)
    issues = [l for l in out.splitlines() if l.strip()]
    report.add("iac-quality", "tflint (no issues)", rc == 0 and not issues, "\n".join(issues[:20]), "tflint")
    # tflint honors inline "# tflint-ignore" comments, which would silence the check from the repo.
    ignores = [f"{f.relative_to(tf)}:{i}: {line.strip()}" for f in tf_files(tf, True)
               for i, line in enumerate(f.read_text(errors="replace").splitlines(), 1) if "tflint-ignore" in line]
    if ignores:
        report.add("iac-quality", "no tflint-ignore annotations", False,
                   "\n".join(ignores[:20]) + "\nFix the finding instead of hiding it.", "tflint")


def check_tftests(repo: Path, report: Report):
    tests = sorted((repo / "terraform/tests").glob("*.tftest.hcl"))
    if report.canonical_tftests is not None:
        tests = [t for t in tests if t.name in report.canonical_tftests]
    if not tests:
        report.notes.append("No terraform tests found in terraform/tests/.")
        return
    for t in tests:
        header = t.read_text(errors="replace")
        m = re.search(r"#\s*rubric:\s*([a-z-]+)", header)
        category = m.group(1) if m else "tests"
        rc, out, err = run([TOOL["terraform"], "test", "-no-color", f"-filter=tests/{t.name}"], repo / "terraform")
        detail = ""
        if rc != 0:
            infra_check(out + err, f"terraform test {t.name}")
            blocks = re.split(r"\n(?=Error: )", out + err)
            errs = [b.strip()[:700] for b in blocks if b.lstrip().startswith("Error: ")]
            detail = "\n\n".join(errs[:3]) or (out + err)[-1500:]
        report.add(category, t.stem.replace(".tftest", "").split("_", 1)[-1].replace("_", " "),
                   rc == 0, detail, f"terraform test {t.name}")


def check_conftest(repo: Path, report: Report):
    if not (repo / "policy").is_dir():
        return
    if not have("conftest"):
        report.skipped_tools.append("conftest")
        return
    # With local modules allowed, the module's resources must be visible to the policies too.
    files = [str(p.relative_to(repo)) for p in
             tf_files(repo / "terraform", bool(report.options.get("_allow_local_modules")))]
    if not files:
        return
    rc, out, err = run([TOOL["conftest"], "test", "--parser", "hcl2", "--combine", "--all-namespaces",
                        "--policy", "policy", "-o", "json", *files], repo)
    try:
        results = json.loads(out)
    except json.JSONDecodeError:
        report.add("iac-quality", "policy evaluation ran", False, (out + err)[-1500:], "conftest")
        return
    for r in results:
        ns = r.get("namespace", "main")
        if ns == "lib":
            continue
        category = NAMESPACE_TO_CATEGORY.get(ns, ns)
        for f in r.get("failures") or []:
            report.add(category, re.sub(r"^\[[a-z-]+\]\s*", "", f["msg"]), False, "", "conftest")
        for _ in range(r.get("successes", 0)):
            report.add(category, f"{category} policy rule", True, "", "conftest")
        for w in r.get("warnings") or []:
            report.notes.append("Warning: " + w["msg"])


def canonical_skips(cfg: Path) -> set[str]:
    if not cfg.exists():
        return set()
    return set(re.findall(r"^\s*-\s*(CKV2?_[A-Z0-9_]+)", cfg.read_text(), re.M))


def check_checkov(repo: Path, report: Report):
    if not have("checkov"):
        report.skipped_tools.append("checkov")
        return
    tf = repo / "terraform"
    cfg = tf / ".checkov.yaml"
    cmd = [TOOL["checkov"], "-d", str(tf), "--framework", "terraform", "terraform_json",
           "--compact", "-o", "json"]  # no --quiet: it drops skipped_checks
    if cfg.exists():
        cmd += ["--config-file", str(cfg)]
    # Run from an empty directory so a .checkov.yaml at the repo root can't narrow the scan.
    scratch = Path(tempfile.mkdtemp(prefix="checkov-cwd-"))
    rc, out, err = run(cmd, scratch, timeout=900)
    shutil.rmtree(scratch, ignore_errors=True)
    try:
        data = json.loads(out)
        data = [d for d in data if isinstance(d, dict)] if isinstance(data, list) else [data]
        failed = [c for d in data for c in d.get("results", {}).get("failed_checks", [])]
        skipped = [c for d in data for c in d.get("results", {}).get("skipped_checks", [])]
        passed = sum(d.get("summary", {}).get("passed", 0) for d in data)
    except (json.JSONDecodeError, IndexError, AttributeError):
        if not out.strip() or '"passed": 0' in out:
            report.add("security", "checkov scanned your Terraform", False,
                       "checkov found nothing to scan in terraform/.", "checkov")
            return
        report.add("security", "checkov output readable", False, (out + err)[-800:], "checkov")
        return
    # Inline #checkov:skip comments only count if the case allows that skip; otherwise the
    # finding stands (rubrics/technical-build.md: an un-reasoned skip counts as the finding).
    allowed = canonical_skips(cfg)
    failed += [c for c in skipped if c.get("check_id") not in allowed]
    # Score security as one check per failing rule id (capped) plus one overall check,
    # so a single noisy rule can't zero the category.
    by_id = {}
    for c in failed:
        by_id.setdefault(c["check_id"], []).append(f'{c["resource"]}: {c["check_name"]}')
    for cid, items in sorted(by_id.items()):
        report.add("security", f"checkov {cid}", False, "\n".join(items[:5]) +
                   "\nFix it, or add it to terraform/.checkov.yaml with a reason you can defend.", "checkov")
    report.add("security", f"checkov baseline ({passed} checks passed)", passed > 0,
               "" if passed else "checkov passed zero checks: nothing was scanned.", "checkov")


def scan_for_review(repo: Path, report: Report):
    """Flag code that only makes sense for tampering with the test run (reported, not scored)."""
    for f in sorted(repo.rglob("*.py")):
        rel = f.relative_to(repo)
        if rel.parts[0] in ("tests", ".git", ".venv", "venv") or ".terraform" in rel.parts:
            continue
        text = f.read_text(errors="replace")
        if rel.parts[0] == "scripts":
            text = text.replace("sys.argv", "")  # command-line helpers may read their arguments
        hits = sorted({m.group(0).strip() for m in REVIEW_PATTERNS.finditer(text)})
        if hits:
            report.review_flags.append(f"{rel}: {', '.join(hits)}")
    if report.review_flags:
        report.notes.append("REVIEW: code that could interfere with the test run (the instructor checks it): "
                            + "; ".join(report.review_flags[:10]))


def check_pytest(repo: Path, report: Report):
    tests = repo / "tests"
    if not tests.is_dir() or not list(tests.glob("test_*.py")):
        return
    rc, _, _ = run([TOOL["python"], "-I", "-c", "import pytest"], repo)
    if rc != 0:
        report.skipped_tools.append("pytest")
        return
    scan_for_review(repo, report)
    tmp = Path(tempfile.mkdtemp(prefix="grade-junit-"))
    junit = tmp / "junit.xml"
    # -I: the repo is not on sys.path, so a pytest.py (or any other module) in it can't
    # shadow the real one; the canonical tests put app/ on the path themselves.
    # --noconftest and an empty ini: a team conftest.py / pytest.ini can't rewrite results.
    rc, out, err = run([TOOL["python"], "-I", "-m", "pytest", "-q", "--tb=line", "--noconftest",
                        "-c", os.devnull, "--rootdir", str(repo), "-p", "no:cacheprovider",
                        f"--junitxml={junit}", "tests"], repo)
    try:
        cases = list(ET.parse(junit).getroot().iter("testcase")) if junit.exists() else None
    except ET.ParseError:
        cases = None
    shutil.rmtree(tmp, ignore_errors=True)
    if cases is None:
        report.add("tests", "pytest ran", False, (out + err)[-1500:], "pytest")
        return
    if not cases:
        report.add("tests", "pytest found tests", False, (out + err)[-1500:], "pytest")
        return

    def outcome(case):
        bad = next((case.find(t) for t in ("failure", "error", "skipped") if case.find(t) is not None), None)
        return bad is None, ((bad.get("message") or bad.tag) if bad is not None else "")[:500]

    canon = report.canonical_pytests
    if canon is None:  # no overlay (a team's own run): report whatever ran
        for case in cases:
            ok, msg = outcome(case)
            report.add("tests", case.get("name", "?").replace("_", " "), ok, msg, "pytest")
        return

    # Score only the canonical test IDs, each exactly once. A passing result for a test the
    # canonical files don't define, or a repeated ID, means something else wrote the results.
    seen, tamper, results = set(), [], {}
    for case in cases:
        cls, name = case.get("classname", ""), case.get("name", "")
        key = (cls, name.split("[", 1)[0])
        ok, msg = outcome(case)
        if (cls, name) in seen:
            tamper.append(f"duplicate result for {cls}::{name}")
        seen.add((cls, name))
        if key not in canon:
            if ok:
                tamper.append(f"passing result for a test the canonical files don't define: {cls}::{name}")
            continue
        results.setdefault(key, []).append((name, ok, msg))
    for key, n in canon.items():
        if n is not None and len(results.get(key, [])) > n:
            tamper.append(f"{key[0]}::{key[1]} reported {len(results[key])} results, expected {n}")
    if tamper:
        report.zero_categories.add("tests")
        report.add("tests", "pytest results match the canonical tests", False,
                   "The tests category scores 0 and the instructor reviews the repo:\n" + "\n".join(tamper[:10]),
                   "pytest")
        return
    for key, n in sorted(canon.items()):
        got = results.get(key, [])
        for name, ok, msg in got:
            report.add("tests", name.replace("_", " "), ok, msg, "pytest")
        for _ in range(max((n if n is not None else 1) - len(got), 0)):
            report.add("tests", key[1].replace("_", " "), False,
                       "Did not run (import or collection error?).\n" + (out + err)[-500:], "pytest")


# --------------------------------------------------------------------------- scoring

def load_weights(repo: Path, report: Report) -> dict:
    """Per-case weights in policy/weights.json put the points on THIS week's new work."""
    f = repo / "policy" / "weights.json"
    if f.exists():
        try:
            w = {k: v for k, v in json.loads(f.read_text()).items() if not k.startswith("_")}
            report.notes.append(f"Case-specific rubric weights: {w}")
            return w
        except (json.JSONDecodeError, AttributeError):
            report.notes.append("policy/weights.json is invalid; default weights used.")
    return dict(WEIGHTS)


def score(report: Report, weights: dict = WEIGHTS) -> dict:
    cats = {}
    for c in report.checks:
        cats.setdefault(c.category, [0, 0])
        cats[c.category][1] += 1
        cats[c.category][0] += int(c.passed)
    present = {k: w for k, w in weights.items() if k in cats}
    unknown = [k for k in cats if k not in WEIGHTS]
    for k in unknown:
        report.notes.append(f"Category '{k}' is not in the rubric; counted under 'tests'.")
        p, t = cats.pop(k)
        cats.setdefault("tests", [0, 0])
        cats["tests"][0] += p
        cats["tests"][1] += t
        present.setdefault("tests", weights.get("tests", WEIGHTS["tests"]))
    total_w = sum(present.values()) or 1
    breakdown = {}
    total = 0.0
    for k, w in present.items():
        p, t = cats[k]
        possible = 100 * w / total_w
        earned = 0.0 if k in report.zero_categories else possible * p / t
        total += earned
        breakdown[k] = {"passed": p, "total": t, "earned": round(earned, 1), "possible": round(possible, 1)}
    return {"score": round(total, 1), "breakdown": breakdown}


def academy_gate(report: Report) -> str:
    """rubrics/technical-build.md: any [academy] failure caps the build at 20/40."""
    return "fail" if any(c.category == "academy" and not c.passed for c in report.checks) else "pass"


def level(pct):
    return ("Exemplary" if pct >= 90 else "Proficient" if pct >= 75
            else "Developing" if pct >= 50 else "Beginning")


def write_reports(report: Report, result: dict, out: Path):
    for p in (out.with_suffix(".json"), out.with_suffix(".md")):
        if p.is_symlink() or p.exists():
            p.unlink()  # never write through a link a team planted
    out.with_suffix(".json").write_text(json.dumps(
        {**result, "academy_gate": academy_gate(report), "checks": [asdict(c) for c in report.checks],
         "skipped_tools": report.skipped_tools, "notes": report.notes,
         "review_flags": report.review_flags}, indent=2))
    L = [f"# Technical build report — {report.repo}", "",
         f"**Automated technical score: {result['score']} / 100** "
         f"(rubric level: {level(result['score'])})", "",
         *([f"**AWS Academy gate: FAIL.** Something here won't deploy in Learner Lab, so the build is "
            f"capped at 20/40 until it's fixed (see the [academy] items below).", ""]
           if academy_gate(report) == "fail" else []),
         "This score covers the *technical build* part of your weekly case (see "
         "`rubrics/technical-build.md`). Your proposal, presentation and cold-call Q&A "
         "are graded by the instructor.", "",
         "| Rubric category | Checks passed | Points |", "|---|---|---|"]
    for k, b in result["breakdown"].items():
        L.append(f"| {k} | {b['passed']}/{b['total']} | {b['earned']} / {b['possible']} |")
    fails = [c for c in report.checks if not c.passed]
    L += ["", f"## What to fix ({len(fails)})", ""]
    if not fails:
        L.append("Nothing — every automated check passed. Now make sure your proposal explains *why*.")
    for c in fails:
        L.append(f"- **[{c.category}] {c.name}** _(via {c.source})_")
        if c.detail:
            L.append("  ```\n  " + c.detail.replace("\n", "\n  ") + "\n  ```")
    passes = [c for c in report.checks if c.passed]
    L += ["", "<details><summary>Passed checks</summary>", ""]
    L += [f"- [{c.category}] {c.name}" for c in passes]
    L += ["", "</details>"]
    if report.skipped_tools or report.notes:
        L += ["", "## Notes", ""]
        L += [f"- Tool not available, not scored: `{t}`" for t in report.skipped_tools]
        L += [f"- {n}" for n in report.notes]
    out.with_suffix(".md").write_text("\n".join(L) + "\n")
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", type=Path)
    ap.add_argument("--overlay", type=Path, help="canonical case dir (autograder/cases/<case>)")
    ap.add_argument("--out", default=None, type=Path, help="report path without extension")
    ap.add_argument("--strict", action="store_true", help="exit 1 if score < 100")
    ap.add_argument("--require-tools", action="store_true",
                    help="exit 2 if any tool is missing (instead of re-weighting the score)")
    a = ap.parse_args()

    repo = a.repo.resolve()
    report = Report(repo=repo.name)
    out = a.out or (repo / "grade-report")
    if a.overlay and not a.overlay.is_dir():
        print(f"ERROR: --overlay {a.overlay} is not a directory. Refusing to grade with the team's own "
              "tests and policies.", file=sys.stderr)
        sys.exit(2)
    links = find_symlinks(repo)
    if links:
        report.add("iac-quality", "no symbolic links in the repo", False,
                   "Found: " + ", ".join(links[:20]) + "\nReplace each link with a real file. Nothing else was graded.",
                   "structure")
        print(write_reports(report, {"score": 0.0, "breakdown": {}, "rejected": "symbolic links"}, out))
        print(f"ERROR: submission rejected, symbolic links: {', '.join(links[:5])}", file=sys.stderr)
        sys.exit(3)
    if a.overlay:
        overlay(a.overlay.resolve(), repo, report)
    load_options(repo, report)

    try:
        grade(repo, report)
    except InfraError as e:
        print(f"ERROR: infrastructure failure (not the team's code); re-run.\n{e}", file=sys.stderr)
        sys.exit(4)

    result = score(report, load_weights(repo, report))
    md = write_reports(report, result, out)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(md)
    print(md)
    if a.require_tools and report.skipped_tools:
        print(f"ERROR: missing tools {report.skipped_tools}; score is not comparable to CI.", file=sys.stderr)
        sys.exit(2)
    sys.exit(1 if a.strict and result["score"] < 100 else 0)


def grade(repo: Path, report: Report):
    check_structure(repo, report)
    if check_terraform(repo, report):
        check_tflint(repo, report)
        check_tftests(repo, report)
        check_checkov(repo, report)
    else:
        report.notes.append("Terraform did not validate, so plan-based tests and security scans were skipped. Fix validation first.")
        # Count every skipped test as failed so an invalid config can't score well.
        for t in sorted((repo / "terraform/tests").glob("*.tftest.hcl")):
            if report.canonical_tftests is not None and t.name not in report.canonical_tftests:
                continue
            m = re.search(r"#\s*rubric:\s*([a-z-]+)", t.read_text(errors="replace"))
            report.add(m.group(1) if m else "tests", t.stem.replace(".tftest", ""), False,
                       "Not run: terraform validate failed.", "terraform test")
        report.add("security", "checkov", False, "Not run: terraform validate failed.", "checkov")
    check_conftest(repo, report)
    check_pytest(repo, report)

if __name__ == "__main__":
    main()
