#!/usr/bin/env bash
# Capture evidence from the installed MoonBit CLI in a disposable fixture copy.
set -euo pipefail
shopt -s nullglob
export RUST_LOG=error

fixture="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
out="$(mktemp -d /tmp/turtles-d2-coverage.XXXXXXXX)"
printf 'Evidence directory: %s\n' "$out"
mkdir "$out/fixture"
sources=(moon.mod moon.pkg probe.mbt probe_test.mbt)
for file in "${sources[@]}"; do
  cp -- "$fixture/$file" "$out/fixture/"
done
cd -- "$out/fixture"

{
  uname -sm
  moon version --all
  moon coverage report --version
  node --version
  sha256sum "${sources[@]}"
} | tee "$out/inputs.log"

run() {
  local log="$1"
  shift
  {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } > "$log" 2>&1 || {
    cat "$log" >&2
    return 1
  }
}

for target in native js; do
  args=(--frozen --debug --target "$target" --enable-coverage --deny-warn)
  run "$out/$target-outline.log" moon test "${args[@]}" --outline \
    --target-dir "$out/$target-outline"
  for selection in full 0 1 2; do
    build="$out/$target-$selection"
    filters=()
    if [[ "$selection" != full ]]; then
      filters=(probe_test.mbt --index "$selection")
    fi
    run "$build.log" moon test "${args[@]}" --verbose --target-dir "$build" "${filters[@]}"
    test_dir="$build/$target/debug/test"
    trace="$test_dir/turtles_coverage_fixture.trace.source"
    runtime=("$build"/moonbit_coverage_*.txt)
    if [[ ! -s "$trace" || ${#runtime[@]} -ne 1 || ! -s "${runtime[0]:-}" ]]; then
      printf 'Expected one fresh runtime log and the source trace for %s/%s\n' \
        "$target" "$selection" >&2
      exit 1
    fi
    run "$build/summary.log" moon coverage report "$trace" -t "${runtime[0]}" -f summary
    run "$build/coveralls.log" moon coverage report "$trace" -t "${runtime[0]}" \
      -f coveralls -o "$build/coveralls.json"
    run "$build/html.log" moon coverage report "$trace" -t "${runtime[0]}" \
      -f html -o "$build/html"

    if [[ "$selection" == full ]]; then
      # Repeat the exact fixture test range directly to retain event interleaving.
      # These are separate diagnostic invocations, outside the CLI capture above.
      if [[ "$target" == native ]]; then
        run "$build/driver.log" "$test_dir/turtles_coverage_fixture.blackbox_test.exe" \
          probe_test.mbt:0-3
      else
        run "$build/driver.log" node --enable-source-maps \
          "$test_dir/turtles_coverage_fixture.blackbox_test.js" probe_test.mbt:0-3
      fi
    fi
    printf 'Collected %s/%s\n' "$target" "$selection"
  done
done
