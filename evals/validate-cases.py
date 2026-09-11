#!/usr/bin/env python3
"""Validate the eval case files against the `claude plugin eval` case schema.

`claude plugin eval` is behind early access on this account, so the suite cannot be run
here to find out whether it parses. This checks it statically instead, against the
schema the CLI actually enforces (Claude Code 2.1.268): every key name, every enum, the
per-grader-type required fields, and the strict-mode rejection of unknown keys.

It is not a substitute for running the suite. It establishes that the files are
well-formed, so that when the harness becomes available the failures that surface are
about agent behaviour rather than about typos in frontmatter.

Usage: evals/validate-cases.py [eval-dir]
Exit status 0 if every case validates.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# --- the schema, as the CLI enforces it -------------------------------------------

# prompt.md frontmatter: keys that land at the top level of the case...
TOP_KEYS = {
    "schema_version", "name", "description", "tags", "plugins", "runs",
    "expected_outcome",
}
# ...and keys that land under `execution`.
EXECUTION_KEYS = {
    "model", "max_turns", "timeout_seconds", "allowed_tools", "artifact_publish",
    "growthbook_overrides", "append_system_prompt", "env",
}

GRADER_TYPES = {"regex", "tool_order", "tool_used", "file_exists", "llm", "baseline"}

# Per-type allowed keys. `name` comes from the filename; the body supplies `criteria`
# for llm/baseline and `pattern` for regex.
GRADER_KEYS = {
    "regex":       {"type", "name", "target", "pattern", "flags", "match", "weight", "arm"},
    "tool_order":  {"type", "name", "before", "after", "weight", "arm"},
    "tool_used":   {"type", "name", "tool", "input_match", "min", "max", "weight", "arm"},
    "file_exists": {"type", "name", "path", "exists", "weight", "arm"},
    "llm":         {"type", "name", "criteria", "focus", "weight", "arm"},
    "baseline":    {"type", "name", "baseline_file", "criteria", "weight", "arm"},
}
GRADER_REQUIRED = {
    "regex":       {"pattern"},
    "tool_order":  {"before", "after"},
    "tool_used":   {"tool"},
    "file_exists": {"path"},
    "llm":         {"criteria"},
    "baseline":    {"baseline_file", "criteria"},
}
# The body of a grader .md fills this key when frontmatter omits it.
BODY_KEY = {"llm": "criteria", "baseline": "criteria", "regex": "pattern"}

TARGETS = {"trace", "last_message", "files", "mock_calls"}
ARMS = {"with-only", "both"}
MATCHES = {"contains", "not_contains"}
FLAGS_RE = re.compile(r"^[dgimsuvy]*$")
COUNT_RE = re.compile(r"^count:\d+$")
TOOL_RE = re.compile(r"^[A-Za-z0-9_-]+$")
TEMPLATE_MARKERS = (
    "TODO: describe what the agent should do",
    "TODO: describe what a successful response looks like",
)

# --- a frontmatter reader for the subset these files use --------------------------

# Line-oriented rather than DOTALL, so that empty frontmatter (`---` immediately
# followed by `---`) matches instead of being misreported as unterminated.
FM_RE = re.compile(r"^---[ \t]*\n((?:.*\n)*?)---[ \t]*(?:\n|\Z)")


def split_frontmatter(text: str) -> tuple[dict | None, str]:
    """Return (frontmatter, body). frontmatter is None when there is none."""
    m = FM_RE.match(text)
    if not m:
        if re.match(r"^---\s*\n", text):
            raise ValueError('unterminated frontmatter (opening "---" with no closing "---")')
        return None, text
    return parse_yaml_subset(m.group(1)), text[m.end():]


def parse_yaml_subset(src: str) -> dict:
    """Parse flat `key: value` YAML with flow lists and `>` folded scalars.

    Deliberately narrow: PyYAML is not available here, and keeping the case files inside
    a subset a 40-line parser can read is a feature, not a limitation. Anything outside
    it raises rather than being silently misread.
    """
    out: dict = {}
    lines = src.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1] in (" ", "\t"):
            raise ValueError(f"unexpected indentation: {line!r}")
        if ":" not in line:
            raise ValueError(f"not a key: value pair: {line!r}")
        key, _, raw = line.partition(":")
        key, raw = key.strip(), raw.strip()
        if raw in (">", "|", ">-", "|-"):
            chunk = []
            while i < len(lines) and (not lines[i].strip() or lines[i][:1] in (" ", "\t")):
                chunk.append(lines[i].strip())
                i += 1
            out[key] = " ".join(c for c in chunk if c)
            continue
        out[key] = parse_scalar(raw, key)
    return out


def parse_scalar(raw: str, key: str):
    if raw.startswith("[") and raw.endswith("]"):
        inner = raw[1:-1].strip()
        return [] if not inner else [parse_scalar(p.strip(), key) for p in inner.split(",")]
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if re.fullmatch(r"-?\d+\.\d+", raw):
        return float(raw)
    return raw


# --- validation -------------------------------------------------------------------

class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.cases = 0
        self.graders = 0

    def err(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")


def positive_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0


def nonneg_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool) and v >= 0


def check_tool_ref(rep: Report, where: str, key: str, value) -> None:
    if isinstance(value, str):
        if not TOOL_RE.match(value):
            rep.err(where, f'{key}: tool name may contain only letters, digits, "_" and "-"')
    elif isinstance(value, dict):
        unknown = set(value) - {"tool", "input_match"}
        if unknown:
            rep.err(where, f"{key}: unknown keys {sorted(unknown)}")
        if "tool" not in value:
            rep.err(where, f"{key}: missing tool")
    else:
        rep.err(where, f"{key}: must be a tool name or a {{tool, input_match}} mapping")


def validate_grader(rep: Report, path: Path, case: str) -> str | None:
    where = f"{case}/graders/{path.name}"
    try:
        fm, body = split_frontmatter(path.read_text())
    except ValueError as e:
        rep.err(where, str(e))
        return None
    if fm is None:
        # The CLI skips grader files with no frontmatter. Silence would hide a typo, so
        # it is reported here.
        rep.err(where, "no frontmatter — the harness would skip this file entirely")
        return None

    gtype = fm.get("type")
    if not isinstance(gtype, str) or gtype not in GRADER_TYPES:
        rep.err(where, f'type must be one of {" | ".join(sorted(GRADER_TYPES))}, got {gtype!r}')
        return None

    name = path.stem
    fields = dict(fm)
    fields["name"] = name
    body = body.strip()
    body_key = BODY_KEY.get(gtype)
    if body_key and body_key not in fields and body:
        fields[body_key] = body
    elif body and not body_key:
        rep.err(where, f"{gtype} graders ignore their body; put the assertion in frontmatter")

    unknown = set(fields) - GRADER_KEYS[gtype]
    if unknown:
        rep.err(where, f"unknown keys for type {gtype}: {sorted(unknown)}")
    missing = GRADER_REQUIRED[gtype] - set(fields)
    if missing:
        rep.err(where, f"missing required: {sorted(missing)}")

    for marker in TEMPLATE_MARKERS:
        if marker in str(fields.get(body_key, "")):
            rep.err(where, "still the blank init template")

    if "weight" in fields and not positive_number(fields["weight"]):
        rep.err(where, f"weight must be a positive number, got {fields['weight']!r}")
    if "arm" in fields and fields["arm"] not in ARMS:
        rep.err(where, f'arm must be one of {" | ".join(sorted(ARMS))}, got {fields["arm"]!r}')

    if gtype == "regex":
        flags = fields.get("flags", "")
        if not isinstance(flags, str) or not FLAGS_RE.match(flags):
            rep.err(where, f"flags must be JS RegExp flags (d g i m s u v y), got {flags!r}")
        match = fields.get("match", "contains")
        if match not in MATCHES and not COUNT_RE.match(str(match)):
            rep.err(where, f"match must be contains | not_contains | count:N, got {match!r}")
        target = fields.get("target", "last_message")
        if isinstance(target, dict):
            if target.get("source") != "file" or "path" not in target:
                rep.err(where, "target mapping must be {source: file, path: ...}")
        elif target not in TARGETS:
            rep.err(where, f'target must be one of {" | ".join(sorted(TARGETS))}, got {target!r}')
        try:
            # Not identical to JS RegExp, but it catches unbalanced groups and bad
            # escapes, which is what a typo here actually looks like.
            re.compile(str(fields.get("pattern", "")))
        except re.error as e:
            rep.err(where, f"pattern does not compile: {e}")

    if gtype == "llm":
        focus = fields.get("focus", "last_message")
        if isinstance(focus, dict):
            if focus.get("source") != "file" or "path" not in focus:
                rep.err(where, "focus mapping must be {source: file, path: ...}")
        elif focus not in TARGETS:
            rep.err(where, f'focus must be one of {" | ".join(sorted(TARGETS))}, got {focus!r}')

    if gtype == "tool_used":
        tool = fields.get("tool")
        if isinstance(tool, str) and not TOOL_RE.match(tool):
            rep.err(where, 'tool name may contain only letters, digits, "_" and "-"')
        for k in ("min", "max"):
            if k in fields and not nonneg_int(fields[k]):
                rep.err(where, f"{k} must be a non-negative integer, got {fields[k]!r}")
        if nonneg_int(fields.get("min")) and nonneg_int(fields.get("max")) \
                and fields["min"] > fields["max"]:
            rep.err(where, f"min {fields['min']} exceeds max {fields['max']}")

    if gtype == "tool_order":
        for k in ("before", "after"):
            if k in fields:
                check_tool_ref(rep, where, k, fields[k])

    if gtype == "file_exists" and "exists" in fields \
            and not isinstance(fields["exists"], bool):
        rep.err(where, f"exists must be a boolean, got {fields['exists']!r}")

    rep.graders += 1
    return name


def validate_case(rep: Report, case_dir: Path) -> str | None:
    case = case_dir.name
    prompt = case_dir / "prompt.md"
    graders_dir = case_dir / "graders"

    if (case_dir / "case.yaml").exists():
        rep.err(case, "case.yaml is not validated by this script; check it by hand")
        return case

    if not prompt.exists():
        rep.err(case, "no prompt.md")
        return None

    try:
        fm, body = split_frontmatter(prompt.read_text())
    except ValueError as e:
        rep.err(f"{case}/prompt.md", str(e))
        return None
    fm = fm or {}

    unknown = set(fm) - TOP_KEYS - EXECUTION_KEYS
    if unknown:
        rep.err(f"{case}/prompt.md",
                f"unknown frontmatter keys {sorted(unknown)} "
                f"(expected one of: {', '.join(sorted(TOP_KEYS | EXECUTION_KEYS))})")

    if not body.strip():
        rep.err(f"{case}/prompt.md", "empty prompt body")
    for marker in TEMPLATE_MARKERS:
        if marker in body:
            rep.err(f"{case}/prompt.md", "still the blank init template")

    # Bounds the CLI enforces.
    for key, hi in (("max_turns", 200), ("timeout_seconds", 3600), ("runs", 50)):
        if key in fm:
            v = fm[key]
            if not isinstance(v, int) or isinstance(v, bool) or v < 1 or v > hi:
                rep.err(f"{case}/prompt.md", f"{key} must be an integer in 1..{hi}, got {v!r}")
    if "allowed_tools" in fm and not isinstance(fm["allowed_tools"], list):
        rep.err(f"{case}/prompt.md", "allowed_tools must be a list")
    if "tags" in fm and not isinstance(fm["tags"], list):
        rep.err(f"{case}/prompt.md", "tags must be a list")
    sv = fm.get("schema_version")
    if sv is not None and not re.match(r"^\d+(\.\d+)*$", str(sv)):
        rep.err(f"{case}/prompt.md", f"schema_version {sv!r} is not a version string")
    elif sv is not None and int(str(sv).split(".")[0]) > 1:
        rep.err(f"{case}/prompt.md", f"schema_version {sv!r} needs a newer Claude Code")

    if not graders_dir.is_dir():
        rep.err(case, "no graders/ directory")
        return case

    grader_files = sorted(graders_dir.glob("*.md"))
    if not grader_files:
        rep.err(case, "graders/ holds no .md files (at least one grader is required)")

    seen: dict[str, int] = {}
    scored = 0
    for g in grader_files:
        name = validate_grader(rep, g, case)
        if name:
            seen[name] = seen.get(name, 0) + 1
            try:
                gfm, _ = split_frontmatter(g.read_text())
            except ValueError:
                gfm = None
            if (gfm or {}).get("arm") != "with-only":
                scored += 1
    for name, n in seen.items():
        if n > 1:
            rep.err(case, f'duplicate grader name "{name}"')
    if grader_files and scored == 0:
        rep.err(case, "every grader is arm: with-only, so the case cannot be scored")

    rep.cases += 1
    return case


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
    rep = Report()

    case_dirs = sorted(
        d for d in root.iterdir()
        if d.is_dir()
        and not d.name.startswith(".")
        and d.name not in {"results", "mocks", "proofs"}
    )
    if not case_dirs:
        print(f"no case directories under {root}", file=sys.stderr)
        return 1

    names: dict[str, int] = {}
    for d in case_dirs:
        name = validate_case(rep, d)
        if name:
            names[name] = names.get(name, 0) + 1
    for name, n in names.items():
        if n > 1:
            rep.err("suite", f'{n} cases share the name "{name}"')

    if rep.errors:
        print(f"{len(rep.errors)} problem(s) in {len(case_dirs)} case directories:")
        for e in rep.errors:
            print(f"  - {e}")
        return 1

    print(f"{rep.cases} cases, {rep.graders} graders: all valid against the "
          f"plugin-eval case schema.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
