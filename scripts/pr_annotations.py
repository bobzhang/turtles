#!/usr/bin/env python3
"""Convert an attested turtles schema-4 diff report to offline annotations."""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import sys
import unicodedata


MAX_INT32 = 2**31 - 1
OUTCOMES = ("killed", "survived", "timeout", "unviable")
VISIBILITIES = ("public", "private", "test")
KILL_KINDS = {"Property": "property", "Snapshot": "snapshot",
              "DocTest": "doc_test", "Assertion": "assertion"}
GROUPS = ("comparison", "boolean", "arithmetic", "literal", "condition", "body", "boundary")
ATTENTION = {
    "SURVIVED": "The test oracle did not kill this mutant.",
    "TIMEOUT": "This mutant exceeded a check or test timeout.",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def reject_constant(_):
    raise ValueError("non-finite JSON number")


def decode_object(raw, label):
    return object_value(json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                                   parse_constant=reject_constant), label)


def object_value(value, label):
    require(type(value) is dict, f"{label} must be an object")
    return value


def integer(value, label, minimum=0):
    require(type(value) is int and minimum <= value <= MAX_INT32,
            f"invalid {label}")
    return value


def text_value(value, label):
    require(type(value) is str and bool(value) and
            not any(unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Zl", "Zp") for ch in value),
            f"invalid {label}")
    return value


def matches(value, pattern, label):
    require(type(value) is str and re.fullmatch(pattern, value) is not None,
            f"invalid {label}")
    return value


def source_path(value):
    text_value(value, "source path")
    require("\\" not in value and re.match(r"[A-Za-z]:", value) is None,
            "unsafe source path")
    for part in value.split("/"):
        require(part.lower() not in ("", ".", "..", ".git"),
                "unsafe source path")
    return value


def fingerprints(value):
    files = object_value(value, "files")
    require(bool(files), "missing source fingerprints")
    for path, digest in files.items():
        source_path(path)
        matches(digest, r"[0-9a-f]{16}", "file fingerprint")
    return files


def diff_selection(value):
    selection = object_value(value, "selection")
    require(selection.keys() == {
        "version", "scope", "discovered", "diff_excluded", "target_inactive", "shard_excluded",
        "selected", "classified", "diff", "shard",
    }, "invalid selection fields")
    require(integer(selection.get("version"), "selection version") == 1 and
            selection.get("scope") == "diff", "expected selection version 1 with diff scope")
    require("shard" in selection and selection["shard"] is None and
            integer(selection.get("shard_excluded"), "shard_excluded") == 0,
            "unsupported shard selection")
    diff = object_value(selection.get("diff"), "diff selection")
    require(diff.keys() == {"fingerprint_algorithm", "fingerprint", "validation"},
            "invalid diff selection fields")
    require(diff.get("fingerprint_algorithm") == "fnv1a64-v1" and
            diff.get("validation") == "represented-new-side-v1", "unknown diff contract")
    matches(diff.get("fingerprint"), r"[0-9a-f]{16}", "diff fingerprint")
    discovered = integer(selection.get("discovered"), "discovered count")
    excluded = integer(selection.get("diff_excluded"), "diff_excluded count")
    inactive = integer(selection.get("target_inactive"), "target_inactive count")
    selected = integer(selection.get("selected"), "selected count")
    classified = integer(selection.get("classified"), "classified count")
    require(classified == selected and discovered == excluded + inactive + selected,
            "inconsistent selection counts")
    return selection


def fnv_hex(data):
    digest = 0xcbf29ce484222325
    for byte in data:
        digest = ((digest ^ byte) * 0x100000001b3) & (2**64 - 1)
    return f"{digest:016x}"


def mutant_id(value):
    return matches(value, r"m-[0-9a-f]{16}", "mutant ID")


def duration(value):
    matches(value, r"0|[1-9][0-9]{0,18}", "duration")
    require(int(value) <= 2**63 - 1, "invalid duration")


def validate_mutant(value, files):
    row = object_value(value, "mutant")
    path = source_path(row.get("path"))
    require(path.endswith(".mbt") and path in files, "mutant source missing from file fingerprints")
    integer(row.get("line"), "mutant line", 1)
    integer(row.get("column"), "mutant column", 1)
    offset = integer(row.get("offset"), "mutant offset")
    end = integer(row.get("end"), "mutant end", offset + 1)
    group = row.get("group")
    require(group in GROUPS, "invalid mutant group")
    for key in ("original", "replacement"):
        require(type(row.get(key)) is str and "\x00" not in row[key], f"invalid mutant {key}")
    identity = "\0".join((path, str(offset), str(end), row["original"], row["replacement"], group))
    require(mutant_id(row.get("id")) == f"m-{fnv_hex(identity.encode('utf-8'))}",
            "mutant ID does not match the reported identity")
    require(row.get("outcome") in ("KILLED", "SURVIVED", "TIMEOUT", "UNVIABLE"),
            "unknown mutant outcome")
    require(row.get("visibility") in VISIBILITIES, "invalid mutant visibility")
    require(type(row.get("reused")) is bool and
            (not row["reused"] or row["outcome"] in ("KILLED", "UNVIABLE")), "invalid mutant reuse")
    duration(row.get("duration_ms"))
    return row


def validate_tally(summary, counts):
    for name in OUTCOMES:
        require(integer(summary.get(name), f"{name} count") == counts[name],
                f"inconsistent {name} count")
    viable = sum(counts[name] for name in ("killed", "survived", "timeout"))
    expected_score = 100 * counts["killed"] / viable if viable else 100
    score = summary.get("score")
    require(type(score) in (int, float) and 0 <= score <= 100 and
            math.isclose(score, expected_score, rel_tol=1e-12, abs_tol=1e-12),
            "inconsistent mutation score")


def validate_summary(summary, rows):
    summary = object_value(summary, "summary")
    validate_tally(summary, Counter(row["outcome"].lower() for row in rows))
    require(integer(summary.get("reused"), "reused count") == sum(row["reused"] for row in rows),
            "inconsistent reused count")
    for visibility in ("public", "private"):
        bucket = object_value(summary.get(f"score_{visibility}"), "visibility summary")
        counts = Counter(row["outcome"].lower() for row in rows if row["visibility"] == visibility)
        require(integer(bucket.get("mutants"), "visibility mutant count") == sum(counts.values()),
                "inconsistent visibility mutant count")
        validate_tally(bucket, counts)

    kills = Counter()
    property_only = 0
    for row in rows:
        if row["outcome"] != "KILLED":
            require("killed_by" not in row, "unexpected kill attribution")
            continue
        attributed = row.get("killed_by")
        require(type(attributed) is list, "invalid kill attribution")
        kinds = []
        for kill in attributed:
            kind = object_value(kill, "kill attribution").get("kind")
            require(type(kind) is str and kind in KILL_KINDS, "unknown kill attribution kind")
            kinds.append(KILL_KINDS[kind])
        kills.update(kinds)
        property_only += bool(kinds) and all(kind == "property" for kind in kinds)
    by_kind = object_value(summary.get("kills_by_kind"), "kill counts")
    for name in KILL_KINDS.values():
        require(integer(by_kind.get(name), "kill attribution count") == kills[name],
                "inconsistent kill attribution count")
    require(integer(summary.get("property_only_kills"), "property-only count") == property_only,
            "inconsistent property-only count")


def verify_manifest(manifest):
    require(integer(manifest.get("version"), "manifest version") == 1, "unknown manifest version")
    require(integer(manifest.get("exit_code"), "invocation exit code") in (0, 1),
            "current invocation did not complete")
    text_value(manifest.get("run_id"), "expected run ID")
    text_value(manifest.get("module"), "expected module")
    require("target" in manifest, "missing expected target")
    if manifest["target"] is not None:
        text_value(manifest["target"], "expected target")
    require(manifest.get("test_scope") in ("module", "affected"), "unknown expected test scope")
    fingerprints(manifest.get("files"))
    diff_selection(manifest.get("selection"))
    lines = object_value(manifest.get("selected_lines"), "expected selected mutant lines")
    for identifier, line in lines.items():
        mutant_id(identifier)
        integer(line, "expected mutant line", 1)
    require(len(lines) == manifest["selection"]["selected"],
            "inconsistent expected selected mutants")
    prefix = manifest.get("module_prefix")
    require(type(prefix) is str, "missing repository-relative module prefix")
    if prefix:
        source_path(prefix)
    matches(manifest.get("report_sha256"), r"[0-9a-f]{64}", "report SHA-256")


def verify_report(report, manifest):
    require(integer(report.get("schema"), "report schema") == 4 and
            report.get("execution") == "completed" and
            "diagnostics" in report and report["diagnostics"] is None,
            "expected a completed schema-4 report with null diagnostics")
    # MoonBit omits absent optional fields, including the default target.
    for name in ("run_id", "module", "target", "test_scope"):
        require(report.get(name) == manifest[name], f"mismatched {name}")
    text_value(report.get("turtles_version"), "turtles version")
    if "moon_version" in report:
        text_value(report["moon_version"], "Moon version")
    files = fingerprints(report.get("files"))
    require(files == manifest["files"], "mismatched source fingerprints")
    selection = diff_selection(report.get("selection"))
    require(selection == manifest["selection"], "mismatched selection metadata")
    inactive_count = integer(report.get("inactive_mutants"), "inactive_mutants count")
    require(inactive_count == selection["target_inactive"], "inconsistent inactive mutant count")
    require(not inactive_count or manifest["target"] is not None, "inactive mutants require a target")
    inactive_files = report.get("inactive_files")
    require(type(inactive_files) is list, "invalid inactive files")
    inactive_paths = {source_path(value) for value in inactive_files}
    require(inactive_paths <= files.keys() and len(inactive_paths) == len(inactive_files) and
            bool(inactive_paths) == bool(inactive_count) and len(inactive_paths) <= inactive_count,
            "inconsistent inactive files")
    require(report.get("skipped_files") == [], "missing skipped_files or incomplete source discovery")
    for name in ("baseline_duration_ms", "baseline_check_ms", "baseline_test_ms"):
        duration(report.get(name))
    mutants = report.get("mutants")
    require(type(mutants) is list and len(mutants) == selection["classified"],
            "inconsistent mutant row count")
    rows = [validate_mutant(value, files) for value in mutants]
    require(inactive_paths.isdisjoint(row["path"] for row in rows),
            "active mutant reported in an inactive file")
    lines = {row["id"]: row["line"] for row in rows}
    require(len(lines) == len(rows), "duplicate mutant ID")
    require(lines == manifest["selected_lines"], "mismatched selected mutant IDs or lines")
    validate_summary(report.get("summary"), rows)
    return rows


def annotations(raw, manifest, cap):
    integer(cap, "annotation cap")
    verify_manifest(manifest)
    require(hashlib.sha256(raw).hexdigest() == manifest["report_sha256"],
            "report SHA-256 does not match the current invocation")
    report = decode_object(raw, "report")
    rows = verify_report(report, manifest)
    candidates = sorted((row for row in rows if row["outcome"] in ATTENTION),
                        key=lambda row: (row["path"], row["line"], row["id"]))
    emitted = []
    for row in candidates[:cap]:
        path = "/".join(filter(None, (manifest["module_prefix"], row["path"])))
        emitted.append({
            "path": path,
            "start_line": row["line"],
            "end_line": row["line"],
            "annotation_level": "warning",
            "title": f"Turtles {row['outcome']}",
            "message": ATTENTION[row["outcome"]],
            "mutant_id": row["id"],
            "evidence": {key: row[key] for key in ("outcome", "group", "original", "replacement")},
            "rerun": {
                "strategy": "repeat-original-invocation-and-locate-id",
                "mutant_id": row["id"],
            },
        })
    return {
        "version": 1,
        "run_id": report["run_id"],
        "report_sha256": manifest["report_sha256"],
        "selection": report["selection"],
        "target": manifest["target"],
        "test_scope": report["test_scope"],
        "annotations": emitted,
        "summary": {
            "annotation_cap": cap,
            "eligible": len(candidates),
            "emitted": len(emitted),
            "omitted": len(candidates) - len(emitted),
            "truncated": len(emitted) < len(candidates),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--annotation-cap", required=True, type=int)
    args = parser.parse_args()
    try:
        manifest = decode_object(args.manifest.read_bytes(), "manifest")
        output = annotations(args.report.read_bytes(), manifest, args.annotation_cap)
        encoded = json.dumps(output, sort_keys=True, indent=2, allow_nan=False)
    except (OSError, UnicodeError, RecursionError, json.JSONDecodeError):
        print("pr_annotations: unable to read or decode input", file=sys.stderr)
        return 2
    except ValueError as error:
        print(f"pr_annotations: {error}", file=sys.stderr)
        return 2
    print(encoded)
    return 0


if __name__ == "__main__":
    sys.exit(main())
