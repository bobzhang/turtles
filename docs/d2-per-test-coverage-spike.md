# D2 MoonBit per-test coverage spike

**Decision: no-go for coverage-driven test selection.** On the installed toolchain,
one ordinary `moon test --enable-coverage` run produced no supported coverage
artifact keyed by test identity. The existing broad test plan and full-run
verdict contract still apply. This spike addresses the capability question in
[D2](../issues/polished/20261117-mutation-testing-quality-program.md#d2-coveragetest-selection先にspike).
The [local issue](../issues/open/20261119-d2-per-test-coverage-spike.md) tracks
this investigation.

| Question | Native | JS |
| --- | --- | --- |
| Official full-suite coverage artifact attributes points to named tests | **No.** Three unnamed counter dumps in one log, merged by the reporter. | **No.** One aggregate counter dump after all three tests. |
| Generated driver stdout retains boundaries usable in this fixture | **Yes, internal only.** A separate full-range invocation emits each dump between matching start/result events. | **No.** Start/result events have indices, but the single dump follows the last result. |
| A fresh official single-test run can be bound externally to a test | **Yes**, for the three observed isolated runs. | **Yes**, for the three observed isolated runs. |
| Source locations distinguish the short-circuit RHS here | **Yes.** HTML marks the RHS separately. | **Yes.** Same point counts and source locations. |
| Isolation preserves original-suite behavior generally | **Unknown.** | **Unknown.** |

## Reproduce

From the repository root, run:

```bash
bash fixtures/per-test-coverage/reproduce.sh
```

The script uses Linux shell utilities, the installed MoonBit toolchain and its
bundled core, plus Node for JS. It copies four fixture inputs to a fresh
`/tmp/turtles-d2-coverage.*` directory and prints the path. Test invocations use
`--frozen` and no external package. Reports run locally through bundled
`moon_cove.wasm`. The script records source hashes, tool versions, the exact
commands and CLI output, the generated test metadata and driver, the original
runtime logs and traces, and the official reports. All generated files stay in
the temporary directory. The two `driver.log` files come from separate
diagnostic invocations of Moon's own generated executables.

Observed on 2026-11-19 JST on Linux x86_64:

| Component | Observed version |
| --- | --- |
| `moon`, `moonrun` | `0.1.20261117 (eb64713 2026-11-17)` |
| `moonc` | `v0.10.21+06da1ed44 (2026-11-16)` |
| Bundled `moonbitlang/core` manifest | `0.10.21+06da1ed44` |
| `moon coverage report --version` | `0.3.3` |
| Node | `v26.13.1` |

The local CLI help (`moon test --help`, `moon coverage --help`,
`moon coverage report --help`) and packaged sources establish the behavior of
this installed version. Examples below use the installed build as observed.
Online source files provide implementation context and may track upstream
changes. The newest upstream download was not independently verified.

The commands below use the copied fixture as the working directory, with
`out` set to the printed evidence directory and `target` set separately to
`native` and `js`. The script expands all variables in the captured commands.

```bash
moon test --frozen --debug --target "$target" --enable-coverage --deny-warn \
  --outline --target-dir "$out/$target-outline"
moon test --frozen --debug --target "$target" --enable-coverage --deny-warn \
  --verbose --target-dir "$out/$target-full"
# For i = 0, 1, 2, each with its own fresh target directory:
moon test --frozen --debug --target "$target" --enable-coverage --deny-warn \
  --verbose --target-dir "$out/$target-$i" probe_test.mbt --index "$i"
# In each build directory, consume exactly its one source trace and runtime log:
moon coverage report "$trace" -t "$runtime" -f summary
moon coverage report "$trace" -t "$runtime" -f coveralls -o "$build/coveralls.json"
moon coverage report "$trace" -t "$runtime" -f html -o "$build/html"
```

## Full-suite and isolated evidence

The package is `f4ah6o/turtles_coverage_fixture`. Both target outlines reported
the same black-box tests in `probe_test.mbt`. Each CLI full run passed 3/3,
and each selected run passed the stated test alone (1/1). Test names are
confirmed by the verbose CLI output. The generated
`__blackbox_test_info.json` lists tests by file with
`{index, func, name, attrs, line_number}` records. It carries no coverage.

| Outline index, line, name | Native isolated vector | JS isolated vector | Points covered |
| --- | --- | --- | --- |
| 0, 2, `left-short-circuits` | `[0, 1, 0, 1, 0]` | `[0, 1, 0, 1, 0]` | 2/5 |
| 1, 10, `right-short-circuits` | `[0, 1, 0, 0, 1]` | `[0, 1, 0, 0, 1]` | 2/5 |
| 2, 18, `property-disabled-probe` | `[0, 8, 0, 0, 0]` | `[0, 8, 0, 0, 0]` | 1/5 |

The ordinary CLI full run produced one file per target in this fixture,
`<target-dir>/moonbit_coverage_<timestamp>_<random>.txt`. Native contained
three delimited blocks with the three vectors above in that order. JS contained
one block with their sum. That exact JS block was:

```text
----- BEGIN MOONBIT COVERAGE -----
{ "f4ah6o/turtles_coverage_fixture$probe": [0, 10, 0, 1, 1]
}
----- END MOONBIT COVERAGE -----
```

Each block is a JSON object mapping compiler counter IDs to arrays of unsigned
hit counts, without a test name, file/index, target, source digest, or run ID.
The runtime text has no separate schema stamp. The source map next to the test
executable, `<target-dir>/<target>/debug/test/turtles_coverage_fixture.trace.source`,
has a 16-byte ASCII header `MOONCOVE00000004` followed by binary metadata
(starting with bytes `84 95 a6 be` here). It relates counter IDs and slots to
package/file/source positions. The two maps were byte-identical for this input
and contained the absolute fixture path. The byte size and file hash therefore
depend on the temporary directory. Use the official reporter to decode them.
[Official coverage reporter and trace schema](https://github.com/moonbitlang/coverage).

The installed native driver calls `@moonbitlang/core/coverage.end()` before
emitting a non-skipped result. The bundled core writes the block and resets the
counters. The JS driver calls it once after executing the range. Running the
generated driver with the same `probe_test.mbt:0-3` argument printed by
`moon test --verbose` showed:

- Native, repeated for each of indices 0, 1, 2: start event with file/index,
  one coverage block, result event with the same file/index and an empty
  success message. Each counter block matched the corresponding isolated run.
- JS: all three start/result pairs, then the one summed block.

Moon's runner captures the coverage and test-result channels separately.
The native `moonbit_coverage_*.txt` alone retains block order but omits the
interleaved identity events. Joining by order would assume that output
boundaries, completion, order and cardinality always correspond. The direct
native observation applies to these synchronous tests on this version. A
private driver protocol and a separate diagnostic invocation do not establish a
supported named coverage export for the original CLI invocation.
[Moon test execution flow](https://github.com/moonbitlang/moon/blob/main/docs/dev/reference/tests.md#test-driver-event-transport),
[Moon runner source](https://github.com/moonbitlang/moon/blob/main/crates/moon/src/run/runtest.rs),
[core coverage writer](https://github.com/moonbitlang/core/blob/main/coverage/coverage.mbt).

The isolated association comes from the target, fresh output directory, module
and package, source snapshot, target-specific outline, and file/index selector
checked against the exact successful name and count. It is coverage of the
selected process, which can also include work such as initialization. Names or
indices alone are insufficient identities across files or revisions.
`--index` requires a single file and implies `--include-skipped`. An extra JS
run with `probe_test.mbt --filter right-short-circuits` matched index 1 and the
same vector. Replacing the filter with `absent-test` exited 0 with zero tests
and no runtime log. Globs can select more than one test, so exit status alone
cannot establish that a particular test ran.
[Moon test command reference](https://docs.moonbitlang.com/en/latest/toolchain/moon/commands.html#moon-test).

## Line coverage and expression reach

Both full reports showed 3/5 points. For `probe.mbt`, the Coveralls JSON uses
`source_files[].{name,source_digest,coverage}` with a zero-based array for
one-based source lines. Non-null entries for lines 3, 9, 14, 19 were
`0, 10, 1, 1` respectively. Null means no reported line count. Line 9
(`enabled && below(x, rhs_calls)`) therefore appears hit in the line format.
The official HTML for the same inputs marks line 9 `mixed`, with 10 hits at
column 3 (`enabled`) and 0 at column 14 (`below`). The generated JS confirms
slot 2 increments inside the short-circuit branch before the call. Slots 0–4
correspond to the `below` entry point, the `probe` entry point, the RHS call
point, and the two distinct helper entry points. Each example uses a local
`Ref` and checks that the RHS did not change it.

The third test is a member of the original fixture suite. It uses bundled core
QuickCheck to run eight generated integer cases with seed 42. The eight hits
form one vector for the entire property test. There is no trial, input, or seed
identity in coverage. An amplified or generated witness would supply evidence
for its own invocation. A hit elsewhere on a line, a null line count, or the
absence of a point for a particular expression cannot establish whether that
expression was evaluated in general.
[Official branch/line report documentation](https://docs.moonbitlang.com/en/latest/toolchain/moon/coverage.html),
[core QuickCheck](https://github.com/moonbitlang/core/tree/main/quickcheck).

## Limits and costs

- **Missing inputs.** Passing an explicit nonexistent trace or runtime log
  returned exit 1. Missing or incomplete artifacts remain unknown, including
  logs from failed or interrupted processes.
- **Stale inputs.** In a second JS copy, prepending a blank line to `probe.mbt`
  after collection still produced a successful Coveralls export. The reporter
  digested the edited source and left the old counts on the old lines. A
  report digest on its own cannot establish that the trace came from the
  displayed source.
- **Target mismatch.** The reporter accepted the JS trace with the native
  full-suite runtime log and printed 3/5. The trace files coincided for this
  fixture, which gives no evidence of interchangeability. Bind maps and logs
  to the same successful invocation, toolchain, target and build flags,
  inputs, test plan and environment. If any are missing, stale, mismatched,
  or ambiguous, selection remains **no-go**. Preserve the broad test plan or
  surface a setup error under the existing contract. AST guesses supply no
  substitute evidence.
- **Overhead.** The fixture used one test process per target for the full
  suite and three for the isolated sweep, each via a fresh CLI build
  directory. The sweep scales to one test launch and coverage capture per
  selected test per target. It can add dependency planning, cold build/link
  work with fresh directories, initialization, and per-run artifact I/O.
  Instrumentation increments counters, then dumps and resets them at the
  backend's flush boundary. Build reuse and wall-clock cost were not measured.
- **Unknowns.** This fixture covers synchronous black-box tests and one fixed
  property configuration. It leaves shared state, ordering, async work, FFI,
  white-box/inline tests, other targets, seed or trial changes, and
  timeout/amplification verdict parity unverified. Full-run verdicts cannot
  be inferred from these coverage counts.

### Repeat the negative artifact checks

Run in the copied fixture directory after the main reproduction. Use the
printed `out` directory. Set `js_trace` to the JS full trace and set
`js_log` and `native_log` to the unique runtime log in the respective full
directory.

```bash
moon coverage report "$js_trace" -t "$out/missing.txt" -f summary
moon coverage report "$out/missing.trace.source" -t "$js_log" -f summary
moon coverage report "$js_trace" -t "$native_log" -f summary

mkdir "$out/stale-source"
cp moon.mod moon.pkg probe.mbt probe_test.mbt "$out/stale-source/"
cd "$out/stale-source"
moon test --frozen --debug --target js --enable-coverage --target-dir "$out/stale-build"
{ printf '\n'; cat probe.mbt; } > probe.shifted
mv probe.shifted probe.mbt
moon coverage report "$out/stale-build/js/debug/test/turtles_coverage_fixture.trace.source" \
  -t "$out"/stale-build/moonbit_coverage_*.txt -f coveralls -o "$out/stale-coveralls.json"
```
