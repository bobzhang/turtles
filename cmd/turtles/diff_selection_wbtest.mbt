///|
test "diff source line offsets preserve UTF-8, CRLF and a bare CR" {
  let lines = diff_source_lines(@utf8.encode("あ\r\nb\rc\nlast"))
  assert_eq(lines.length(), 3)
  assert_eq((lines[0].start, lines[0].content_end, lines[0].end), (0, 3, 5))
  assert_eq((lines[1].start, lines[1].content_end, lines[1].end), (5, 8, 9))
  assert_eq((lines[2].start, lines[2].content_end, lines[2].end), (9, 13, 13))
  assert_false(lines[2].has_newline)
  assert_eq(diff_source_lines(b"").length(), 0)
  assert_eq(diff_source_lines(b"x\n").length(), 1)
}

///|
test "validate represented lines and merge only adjacent additions" {
  let lines : Array[DiffNewLine] = [
    { number: 1, hunk: 1, content: b"a", has_newline: true, added: false, },
    {
      number: 2,
      hunk: 1,
      content: @utf8.encode("あ"),
      has_newline: true,
      added: true,
    },
    { number: 3, hunk: 1, content: b"b", has_newline: true, added: true, },
    { number: 4, hunk: 2, content: b"c", has_newline: false, added: false, },
  ]
  let ranges = validate_diff_new_lines(
    "change.diff",
    "src/a.mbt",
    @utf8.encode("a\nあ\r\nb\nc"),
    lines,
  )
  assert_eq(ranges.length(), 1)
  assert_eq((ranges[0].start, ranges[0].end), (2, 9))
  assert_true(diff_ranges_intersect(0, 3, ranges[0]))
  assert_true(diff_ranges_intersect(8, 10, ranges[0]))
  assert_false(diff_ranges_intersect(0, 2, ranges[0]))
  assert_false(diff_ranges_intersect(9, 10, ranges[0]))
  assert_false(diff_ranges_intersect(3, 3, ranges[0]))
}

///|
test "validate rejects stale content, missing lines and wrong final newline" {
  let original : DiffNewLine = {
    number: 1,
    hunk: 2,
    content: b"x",
    has_newline: true,
    added: true,
  }
  assert_true(
    (Some(validate_diff_new_lines("d", "a.mbt", b"y\n", [original])) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(validate_diff_new_lines("d", "a.mbt", b"x", [original])) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(validate_diff_new_lines("d", "a.mbt", b"", [original])) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(
      validate_diff_new_lines("d", "a.mbt", b"x\n", [{ ..original, number: 0, }]),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "separate additions do not select an unchanged line" {
  let represented : Array[DiffNewLine] = [
    { number: 1, hunk: 1, content: b"a", has_newline: true, added: true, },
    { number: 2, hunk: 1, content: b"b", has_newline: true, added: false, },
    { number: 3, hunk: 1, content: b"c", has_newline: false, added: true, },
  ]
  let ranges = validate_diff_new_lines("d", "a.mbt", b"a\nb\nc", represented)
  assert_eq(ranges.length(), 2)
  assert_eq((ranges[0].start, ranges[0].end), (0, 2))
  assert_eq((ranges[1].start, ranges[1].end), (4, 5))
  assert_false(diff_ranges_intersect(2, 4, ranges[0]))
  assert_false(diff_ranges_intersect(2, 4, ranges[1]))
  assert_false(diff_ranges_intersect(0, 5, { start: 2, end: 2, }))
}

///|
test "diff comparison normalizes CRLF but keeps bare CR on unterminated lines" {
  let line : DiffNewLine = {
    number: 1,
    hunk: 1,
    content: b"x\r",
    has_newline: true,
    added: true,
  }
  assert_eq(validate_diff_new_lines("d", "a.mbt", b"x\n", [line]).length(), 1)
  assert_eq(validate_diff_new_lines("d", "a.mbt", b"x\r\n", [line]).length(), 1)
  assert_eq(
    validate_diff_new_lines("d", "a.mbt", b"x\r", [
      { ..line, has_newline: false, },
    ]).length(),
    1,
  )
  assert_true(
    (Some(
      validate_diff_new_lines("d", "a.mbt", b"x", [
        { ..line, has_newline: false, },
      ]),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
async test "diff selection validates excluded test sources and preserves mutant order" {
  let root = @fs.tmpdir(prefix="turtles-diff-select")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.write_file(path_join(root, "a.mbt"), "first\nsecond\n")
    @fs.write_file(path_join(root, "a_test.mbt"), "test\n")
    let sections = parse_unified_sections(
      b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1,2 +1,2 @@\n first\n-old\n+second\n--- a/a_test.mbt\n+++ b/a_test.mbt\n@@ -1 +1 @@\n-old\n+test\n",
    )
    let base : Mutation = {
      path: "a.mbt",
      start: 0,
      end: 5,
      line: 1,
      column: 1,
      group: Literal,
      original: "first",
      replacement: "x",
      visibility: Private,
    }
    let candidates = [
      base,
      { ..base, start: 6, end: 12, },
      { ..base, start: 3, end: 8, },
    ]
    let inputs = prepare_diff_inputs(root, "changes.diff", sections)
    let selection = select_diff_mutations(inputs, candidates)
    assert_eq(selection.mutations.length(), 2)
    assert_eq(selection.excluded, 1)
    assert_eq(selection.mutations[0].start, 6)
    assert_eq(selection.mutations[1].start, 3)
    assert_eq(inputs.snapshots.length(), 2)
    verify_diff_snapshots(root, inputs.snapshots)
    @fs.write_file(path_join(root, "a_test.mbt"), "stale\n")
    assert_true(
      (Some(prepare_diff_inputs(root, "changes.diff", sections)) catch {
        _ => None
      })
      is None,
    )
    assert_true(
      (Some(verify_diff_snapshots(root, inputs.snapshots)) catch { _ => None })
      is None,
    )
  })
}

///|
test "half-open intersection agrees with discrete byte membership" {
  for start in 0..<8 {
    for end in start..<=8 {
      for left in 0..<8 {
        for right in left..<=8 {
          let mut common = false
          for byte in 0..<8 {
            if start <= byte && byte < end && left <= byte && byte < right {
              common = true
            }
          }
          assert_eq(
            diff_ranges_intersect(start, end, { start: left, end: right, }),
            common,
          )
        }
      }
    }
  }
}

///|
async test "represented MoonBit source containing NUL is rejected" {
  let root = @fs.tmpdir(prefix="turtles-diff-binary-source")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.write_file(path_join(root, "a.mbt"), b"a\x00b\n")
    let patch = b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+a\x00b\n"
    let sections = parse_diff_sections(patch)
    assert_true(
      (Some(prepare_diff_inputs(root, "d", sections)) catch { _ => None })
      is None,
    )
  })
}

///|
async test "added sources require complete content while empty additions stay valid" {
  let root = @fs.tmpdir(prefix="turtles-added-source")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let file = path_join(root, "new.mbt")
    let header = b"diff --git a/new.mbt b/new.mbt\nnew file mode 100644\nindex 0000000..abcdef0\n"
    let truncated = parse_diff_sections(header)
    @fs.write_file(file, "one\ntwo\n")
    assert_true(
      (Some(prepare_diff_inputs(root, "patch", truncated)) catch { _ => None })
      is None,
    )
    let partial = parse_diff_sections(
      b"--- /dev/null\n+++ b/new.mbt\n@@ -0,0 +1 @@\n+one\n",
    )
    assert_true(
      (Some(prepare_diff_inputs(root, "patch", partial)) catch { _ => None })
      is None,
    )
    let complete = parse_diff_sections(
      b"--- /dev/null\n+++ b/new.mbt\n@@ -0,0 +1,2 @@\n+one\n+two\n",
    )
    let selected = prepare_diff_inputs(root, "patch", complete)
    assert_eq(selected.ranges["new.mbt"][0].end, 8)
    @fs.write_file(file, "")
    let empty = prepare_diff_inputs(root, "patch", truncated)
    assert_true(empty.ranges["new.mbt"].is_empty())
  })
}
