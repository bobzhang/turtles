# Offline PR annotations

`scripts/pr_annotations.py` converts a completed turtles schema-4
`--in-diff` report into JSON using the Python standard library. Try it with
the checked-in synthetic fixtures from the repository root.

```sh
python3 scripts/pr_annotations.py \
  --report scripts/tests/fixtures/pr_annotations/completed.json \
  --manifest scripts/tests/fixtures/pr_annotations/trusted-completed.json \
  --annotation-cap 10
```

The CLI writes one JSON object to stdout on success. An input or validation
error exits 2 with a diagnostic on stderr and empty stdout. The explicit cap
can be zero. The generator validates the full report before capping output.
Only `SURVIVED` and `TIMEOUT` yield warnings, ordered by path, line, and mutant
ID. The summary gives eligible, emitted, and omitted counts. The selection
counts describe the completed diff scope, including when that scope is empty.
Runs with skipped source files and reports in configured or sharded scope
are outside this slice. Interrupted runs have no annotation or progress
output.

Annotations contain repository-relative paths, one-based lines, mutant IDs,
and structured verdict and edit evidence. Paths use logical POSIX syntax
with `/` separators. Punctuation and trailing periods or spaces in names are
preserved. Absolute, drive-qualified, and UNC paths are rejected, as are
backslashes, control characters, and empty, `.`, `..`, or `.git` components
(`.git` is matched case-insensitively). Treat paths and edit text as data
when rendering them in another system. The CLI makes no network requests.

## Trusted caller manifest, version 1

Supply a manifest from a trusted runner or an independent attestation for
the **current** invocation. The report and manifest are separate inputs.
[The example manifest](../scripts/tests/fixtures/pr_annotations/trusted-completed.json)
shows the exact JSON shape.

| Field | Expected value and origin |
| --- | --- |
| `version` | Integer `1`, the manifest format version. |
| `exit_code` | Current turtles process status observed by the caller. Both `0` and `1` can represent a completed run. Setup or baseline failure yields `2`. Signals, cancellation, and budget interruption also invalidate the handoff. |
| `run_id` | Producer-assigned ID from an independent trusted observation of the current invocation. |
| `module`, `module_prefix` | Resolved module directory as reported by turtles, and its checked-out repository-relative prefix from the caller. Use an empty prefix for a root module. |
| `target`, `test_scope` | Expected target (required in both manifest and report, explicit `null` for the default; an omitted report target is rejected) and effective oracle scope (`module` or `affected`). |
| `files` | Complete module-relative FNV-1a-64 fingerprint map of the expected source, tests, configuration and manifests, using the producer's file inventory rules. |
| `selection` | Expected schema-4 version-1 diff selection object. Include the fingerprint of the exact raw diff bytes, validation dialect, and all counts. |
| `selected_lines` | Independently expected mapping of every selected mutant ID to its one-based source line, from the same inputs and selection. `--in-diff … --list` exposes the active IDs and positions. |
| `report_sha256` | SHA-256 of the exact bytes bound to the invocation at the trusted artifact handoff. |

Use a fresh artifact destination for each invocation. Record the actual exit
status and bind the manifest to that invocation, even on failure. A manifest
with just `version` and the observed failure status is sufficient for the CLI to
reject a leftover report. The caller must establish the checkout, diff, and
selection expectations independently of the candidate report. Do not copy
fields from the candidate or hash it after the fact to make it pass. The
producer's FNV fingerprints detect ordinary changes. SHA-256 binds the bytes
to the trusted manifest. The CLI depends on the caller for manifest freshness
and authenticity, and for associating the fingerprints with the intended PR
inputs. Replaying an old report and its old trusted manifest together defeats
that assumption.

The current producer creates `run_id` after classification and exposes it
only in the report. Stock turtles therefore cannot supply the independent ID
observation by itself. A trusted caller with a separate producer-side
observation is required for real runs. This slice defines and tests the offline
contract with synthetic fixtures. Producer instrumentation and CI integration
are follow-up work.

## Rechecking a warning

The rerun entry is a structured instruction to repeat the original invocation
with the same checkout, diff, toolchain, target, and options, then locate the
specified ID in the new report. Use `--in-diff … --list` with matching selection
options to inspect the scope first. The current CLI runs the selected scope as
a whole. Mutant IDs include byte offsets and can change after edits. If the
identity changes or the ID is absent, the previous mutant remains unverified.
