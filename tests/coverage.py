#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run the Bash test suite and generate dependency-free coverage reports."""

from __future__ import annotations

import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as element_tree
from dataclasses import dataclass
from pathlib import Path

TRACE_PREFIX = "PWAS_COVERAGE"
TRACE_SEPARATOR = "\x1f"
TRACE_PATTERN = re.compile(
    r"\++"
    + re.escape(TRACE_PREFIX + TRACE_SEPARATOR)
    + r"(?P<source>[^"
    + TRACE_SEPARATOR
    + r"]*)"
    + re.escape(TRACE_SEPARATOR)
    + r"(?P<line>[0-9]+)"
    + re.escape(TRACE_SEPARATOR)
)
IGNORED_KEYWORDS = {
    "(",
    ")",
    ";&",
    ";;",
    ";;&",
    "do",
    "done",
    "elif",
    "else",
    "esac",
    "fi",
    "if",
    "then",
    "while",
    "{",
    "}",
}
SHELL_NAME_PATTERN = r"[A-Za-z_@][A-Za-z0-9_@.:-]*"
FUNCTION_PATTERN = re.compile(
    rf"^(?:{SHELL_NAME_PATTERN}\s*\(\)|"
    + rf"function\s+{SHELL_NAME_PATTERN}(?:\s*\(\))?)\s*(?:\{{\s*)?$"
)
CASE_START_PATTERN = re.compile(r"^case(?:\s|$).*\bin\s*$")
CASE_ENDINGS = (";;", ";&", ";;&")
ARRAY_NAME_PATTERN = r"\b[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]+\])?"
ARRAY_PATTERN = re.compile(ARRAY_NAME_PATTERN + r"\s*=\s*\(")
HEREDOC_PATTERN = re.compile(
    r"<<-?\s*['\"]?(?P<delimiter>[A-Za-z_][A-Za-z0-9_]*)['\"]?"
)
COMMENT_BOUNDARIES = ";|&()"


@dataclass(frozen=True)
class CoverageStats:
    """Aggregate executable-line coverage values."""

    covered: int
    total: int
    percentage: float
    uncovered: tuple[int, ...]


def clean_shell_line(line: str) -> str:
    """Remove an unquoted trailing shell comment and surrounding whitespace."""
    state: str | None = None
    escaped = False
    for index, character in enumerate(line):
        if escaped:
            escaped = False
            continue
        if character == "\\" and state != "'":
            escaped = True
            continue
        if state is None and character in {"'", '"', "`"}:
            state = character
            continue
        if state == character:
            state = None
            continue
        if character == "#" and state is None:
            boundary = index == 0 or line[index - 1].isspace()
            boundary = boundary or line[index - 1] in COMMENT_BOUNDARIES
            if boundary:
                return line[:index].strip()
    return line.strip()


def is_relevant_line(line: str) -> bool:
    """Return whether a physical line represents executable shell code."""
    cleaned = clean_shell_line(line)
    if not cleaned or cleaned in IGNORED_KEYWORDS:
        return False
    if cleaned.startswith("#"):
        return False
    if FUNCTION_PATTERN.fullmatch(cleaned):
        return False
    return not cleaned.endswith("(")


def quote_state(text: str, initial: str | None = None) -> str | None:
    """Return the unclosed shell quote after scanning text."""
    state = initial
    escaped = False
    for character in text:
        if escaped:
            escaped = False
            continue
        if character == "\\" and state != "'":
            escaped = True
            continue
        if state is None and character in {"'", '"', "`"}:
            state = character
        elif state == character:
            state = None
    return state


def continuation_line(line: str) -> bool:
    """Return whether a shell line ends with an unescaped backslash."""
    trailing = len(line.rstrip()) - len(line.rstrip().rstrip("\\"))
    return trailing % 2 == 1


def heredoc_end(lines: list[str], start: int, delimiter: str) -> int:
    """Find the final physical line of a heredoc."""
    for index in range(start + 1, len(lines)):
        if lines[index].lstrip("\t").strip() == delimiter:
            return index
    return start


def array_end(lines: list[str], start: int) -> int:
    """Find the final physical line of a multiline array assignment."""
    for index in range(start + 1, len(lines)):
        if clean_shell_line(lines[index]).startswith(")"):
            return index
    return start


def quote_end(lines: list[str], start: int, state: str) -> int:
    """Find the final physical line of a multiline quoted string."""
    current: str | None = state
    for index in range(start + 1, len(lines)):
        current = quote_state(lines[index], current)
        if current is None:
            return index
    return start


def continuation_end(lines: list[str], start: int) -> int:
    """Find the final physical line of a backslash continuation."""
    index = start
    while index + 1 < len(lines) and continuation_line(lines[index]):
        index += 1
    return index


def skip_case_structure(cleaned: str, case_labels: list[bool]) -> bool:
    """Update case state and identify non-executable structural lines."""
    if cleaned == "esac":
        if case_labels:
            _ = case_labels.pop()
        return True
    if not case_labels or not case_labels[-1]:
        return False
    if cleaned.endswith(")"):
        case_labels[-1] = False
        return True
    if ")" in cleaned:
        case_labels[-1] = False
    return False


def finish_case_line(cleaned: str, case_labels: list[bool]) -> None:
    """Update case state after processing an executable source line."""
    if CASE_START_PATTERN.match(cleaned):
        case_labels.append(True)
    elif case_labels and cleaned.endswith(CASE_ENDINGS):
        case_labels[-1] = True


def executable_groups(lines: list[str]) -> tuple[set[int], dict[int, int]]:
    """Map physical source lines to executable logical command leaders."""
    executable: set[int] = set()
    owners: dict[int, int] = {}
    case_labels: list[bool] = []
    index = 0

    while index < len(lines):
        cleaned = clean_shell_line(lines[index])
        if skip_case_structure(cleaned, case_labels):
            index += 1
            continue
        end = index
        heredoc = HEREDOC_PATTERN.search(cleaned)
        array_match = ARRAY_PATTERN.search(cleaned)
        state = quote_state(cleaned)

        if heredoc:
            end = heredoc_end(lines, index, heredoc.group("delimiter"))
        elif array_match and not cleaned.rstrip().endswith(")"):
            end = array_end(lines, index)
        elif state is not None:
            end = quote_end(lines, index, state)
        elif continuation_line(cleaned):
            end = continuation_end(lines, index)

        if end > index or is_relevant_line(lines[index]):
            leader = index + 1
            for line_number in range(leader, end + 2):
                executable.add(line_number)
                owners[line_number] = leader
        finish_case_line(cleaned, case_labels)
        index = end + 1

    return executable, owners


def validate_parser() -> None:
    """Check lexer behavior that protects the coverage denominator."""
    quoted = 'debug "sink-input #${idx}" # trailing comment'
    if clean_shell_line(quoted) != 'debug "sink-input #${idx}"':
        raise RuntimeError("quoted comment marker was parsed as a comment")
    if not is_relevant_line("_ts() { date '+%H:%M:%S'; }"):
        raise RuntimeError("one-line function body was ignored")
    if is_relevant_line("_ts() {"):
        raise RuntimeError("standalone function header was executable")
    sample = ['case "$value" in', "choice)", "cur=$(pactl info)", ";;", "esac"]
    executable, _owners = executable_groups(sample)
    if 2 in executable or 3 not in executable:
        raise RuntimeError("case label detection hid an executable command")


def run_tests(root: Path, trace_path: Path, passes: int) -> int:
    """Run all tests with Bash xtrace inherited by child shells."""
    environment = os.environ.copy()
    bootstrap_path = trace_path.with_suffix(".bash")
    bootstrap = "export SHELLOPTS\nset -x\n"
    _ = bootstrap_path.write_text(bootstrap, encoding="utf-8")
    environment["BASH_ENV"] = str(bootstrap_path)
    environment["PS4"] = (
        f"+{TRACE_PREFIX}{TRACE_SEPARATOR}"
        "${BASH_SOURCE-}"
        f"{TRACE_SEPARATOR}"
        "${LINENO-}"
        f"{TRACE_SEPARATOR}"
    )
    environment["TEST_PASSES"] = str(passes)

    try:
        with trace_path.open("wb") as trace_file:
            environment["BASH_XTRACEFD"] = str(trace_file.fileno())
            result = subprocess.run(
                ["bash", str(root / "tests" / "run.sh")],
                cwd=root,
                env=environment,
                pass_fds=(trace_file.fileno(),),
                check=False,
            )
    finally:
        bootstrap_path.unlink(missing_ok=True)

    return result.returncode


def trace_hits(root: Path, source: Path, trace: Path) -> dict[int, int]:
    """Parse xtrace records for the source file under coverage."""
    target = source.resolve()
    hits: dict[int, int] = {}
    with trace.open(encoding="utf-8", errors="replace") as trace_file:
        for trace_line in trace_file:
            match = TRACE_PATTERN.search(trace_line)
            if match is None:
                continue
            traced_path = Path(match.group("source"))
            if not traced_path.is_absolute():
                traced_path = root / traced_path
            if traced_path.resolve() != target:
                continue
            line_number = int(match.group("line"))
            hits[line_number] = hits.get(line_number, 0) + 1
    return hits


def coverage_records(
    lines: list[str], raw_hits: dict[int, int]
) -> list[tuple[int, str, int | None]]:
    """Combine executable-line detection with physical xtrace hits."""
    executable, owners = executable_groups(lines)
    for line_number in raw_hits:
        if 1 <= line_number <= len(lines) and line_number not in owners:
            executable.add(line_number)
            owners[line_number] = line_number

    owner_hits: dict[int, int] = {}
    for line_number, count in raw_hits.items():
        owner = owners.get(line_number, line_number)
        owner_hits[owner] = owner_hits.get(owner, 0) + count

    return [
        (
            line_number,
            text,
            (
                owner_hits.get(owners[line_number], 0)
                if line_number in executable
                else None
            ),
        )
        for line_number, text in enumerate(lines, start=1)
    ]


def measure_coverage(
    lines: list[str], raw_hits: dict[int, int]
) -> tuple[list[tuple[int, str, int | None]], CoverageStats]:
    """Calculate line records and aggregate coverage values."""
    records = coverage_records(lines, raw_hits)
    measured = [hits for _number, _text, hits in records if hits is not None]
    covered = sum(hits > 0 for hits in measured)
    total = len(measured)
    percentage = covered * 100 / total if total else 100.0
    uncovered: list[int] = []
    for line_number, _text, hits in records:
        if hits == 0:
            uncovered.append(line_number)
    stats = CoverageStats(covered, total, percentage, tuple(uncovered))
    return records, stats


def write_json(path: Path, source_name: str, stats: CoverageStats) -> None:
    """Write a stable machine-readable coverage summary."""
    payload = {
        "coverage": {
            source_name: {
                "covered_lines": stats.covered,
                "total_lines": stats.total,
                "lines_covered_percent": stats.percentage,
                "uncovered_lines": stats.uncovered,
            }
        }
    }
    report = json.dumps(payload, indent=2) + "\n"
    _ = path.write_text(report, encoding="utf-8")


def add_xml_source(root: element_tree.Element[str]) -> None:
    """Add the source-directory element required by Cobertura."""
    sources = element_tree.SubElement(root, "sources")
    element_tree.SubElement(sources, "source").text = "."


def write_cobertura_report(
    path: Path,
    source_name: str,
    records: list[tuple[int, str, int | None]],
    stats: CoverageStats,
) -> None:
    """Write a minimal Cobertura-compatible XML line report."""
    rate = stats.covered / stats.total if stats.total else 1.0
    root = element_tree.Element(
        "coverage",
        {
            "branch-rate": "0",
            "branches-covered": "0",
            "branches-valid": "0",
            "complexity": "0",
            "line-rate": f"{rate:.6f}",
            "lines-covered": str(stats.covered),
            "lines-valid": str(stats.total),
            "timestamp": str(int(time.time())),
            "version": "pipewire-audio-share",
        },
    )
    add_xml_source(root)
    packages = element_tree.SubElement(root, "packages")
    package = element_tree.SubElement(
        packages,
        "package",
        {
            "branch-rate": "0",
            "complexity": "0",
            "line-rate": f"{rate:.6f}",
            "name": "pipewire-audio-share",
        },
    )
    classes = element_tree.SubElement(package, "classes")
    class_node = element_tree.SubElement(
        classes,
        "class",
        {
            "branch-rate": "0",
            "complexity": "0",
            "filename": source_name,
            "line-rate": f"{rate:.6f}",
            "name": source_name,
        },
    )
    _ = element_tree.SubElement(class_node, "methods")
    xml_lines = element_tree.SubElement(class_node, "lines")
    for line_number, _text, hits in records:
        if hits is not None:
            _ = element_tree.SubElement(
                xml_lines,
                "line",
                {
                    "branch": "false",
                    "hits": str(hits),
                    "number": str(line_number),
                },
            )
    element_tree.indent(root, space="  ")
    report = element_tree.ElementTree(root)
    report.write(path, encoding="utf-8", xml_declaration=True)


def write_html_report(
    path: Path,
    source_name: str,
    records: list[tuple[int, str, int | None]],
    stats: CoverageStats,
) -> None:
    """Write a standalone human-readable HTML line report."""
    rows: list[str] = []
    for line_number, source_line, hits in records:
        if hits is None:
            state = "ignored"
            hit_text = ""
        elif hits > 0:
            state = "covered"
            hit_text = str(hits)
        else:
            state = "uncovered"
            hit_text = "0"
        row = (
            f'<tr class="{state}"><td>{hit_text}</td><td>{line_number}</td>'
            + f"<td><code>{html.escape(source_line.rstrip())}</code></td></tr>"
        )
        rows.append(row)

    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coverage for {html.escape(source_name)}</title>
<style>
body {{ font-family: sans-serif; margin: 2rem; }}
table {{ border-collapse: collapse; width: 100%; }}
td {{ padding: 0 0.5rem; vertical-align: top; white-space: pre; }}
td:first-child, td:nth-child(2) {{ text-align: right; width: 1%; }}
.covered {{ background: #e6ffed; }}
.uncovered {{ background: #ffeef0; }}
.ignored {{ color: #666; }}
</style>
</head>
<body>
<h1>{html.escape(source_name)}</h1>
<p>Line coverage: <strong>{stats.percentage:.2f}%</strong></p>
<table>
<tbody>
{"".join(rows)}
</tbody>
</table>
</body>
</html>
"""
    _ = path.write_text(document, encoding="utf-8")


def write_summary(path: Path, stats: CoverageStats, threshold: float) -> None:
    """Write the Markdown summary consumed by GitHub Actions."""
    summary = (
        "## Test coverage\n\n"
        f"Line coverage: **{stats.percentage:.2f}%** "
        f"({stats.covered} / {stats.total} lines)\n\n"
        f"Required minimum: **{threshold:.2f}%**\n"
    )
    _ = path.write_text(summary, encoding="utf-8")


def main() -> int:
    """Run tests, emit reports, and enforce the configured threshold."""
    root = Path(__file__).resolve().parents[1]
    validate_parser()
    source_path = root / "pipewire-audio-share.sh"
    coverage_dir = root / "coverage"
    threshold = float(os.environ.get("MINIMUM_COVERAGE", "95"))
    passes = int(os.environ.get("TEST_PASSES", "3"))

    shutil.rmtree(coverage_dir, ignore_errors=True)
    coverage_dir.mkdir()
    trace_path = coverage_dir / "xtrace.log"
    test_status = run_tests(root, trace_path, passes)
    if test_status != 0:
        failure = "Test suite failed; coverage was not calculated."
        print(failure, file=sys.stderr)
        return test_status

    source_lines = source_path.read_text(encoding="utf-8").splitlines()
    raw_hits = trace_hits(root, source_path, trace_path)
    trace_path.unlink()
    records, stats = measure_coverage(source_lines, raw_hits)

    write_json(coverage_dir / "coverage.json", source_path.name, stats)
    write_cobertura_report(
        coverage_dir / "coverage.xml", source_path.name, records, stats
    )
    html_path = coverage_dir / "index.html"
    write_html_report(html_path, source_path.name, records, stats)
    write_summary(coverage_dir / "summary.md", stats, threshold)

    coverage_message = (
        f"Line coverage: {stats.percentage:.2f}% "
        + f"({stats.covered} / {stats.total} lines)"
    )
    print(coverage_message)
    if stats.percentage < threshold:
        print(
            f"Coverage is below the required {threshold:.2f}% minimum.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
