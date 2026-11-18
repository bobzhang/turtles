///|
test "hunk headers parse defaults and reject malformed or overflowing ranges" {
  assert_eq(diff_hunk_header(b"@@ -1 +3 @@ fn"), (1, 1, 3, 1))
  assert_eq(diff_hunk_header(b"@@ -0,0 +1,2 @@"), (0, 0, 1, 2))
  for
    bad in [
      b"@@@ -1 +1 @@@", b"@@ -0 +1 @@", b"@@ -1,0 +1,0 @@", b"@@ -2147483647 +1 @@",
      b"@@ -1,2147483648 +1 @@", b"@@ -1 +1 @@suffix", b"@@ -1 +x @@",
    ] {
    assert_true((Some(diff_hunk_header(bad)) catch { _ => None }) is None)
  }
}

///|
test "hunks enforce both counts and retain only new-side lines" {
  let input = [
    b"@@ -1,2 +1,2 @@", b" same", b"-old", b"+new", b"\\ No newline at end of file",
    b"@@ -4 +4 @@",
  ]
  let (hunk, next) = parse_diff_hunk(input, 0, 3)
  assert_eq(next, 5)
  assert_eq(hunk.lines.length(), 2)
  assert_false(hunk.lines[0].added)
  assert_true(hunk.lines[1].added)
  assert_false(hunk.lines[1].has_newline)
  let ranges = validate_diff_new_lines("d", "a.mbt", b"same\nnew", hunk.lines)
  assert_eq((ranges[0].start, ranges[0].end), (5, 8))
  for
    bad in [
      [b"@@ -1,2 +1 @@", b"-old", b"+new"],
      [
        b"@@ -1 +1 @@", b"-old", b"+new", b"\\ No newline at end of file", b"\\ No newline at end of file",
      ],
      [
        b"@@ -1 +1,2 @@", b"-old", b"+one", b"\\ No newline at end of file", b"+two",
      ],
    ] {
    assert_true((Some(parse_diff_hunk(bad, 0, 1)) catch { _ => None }) is None)
  }
}

///|
test "hunk validation rejects out-of-range deletions and overlapping sections" {
  let (first, _) = parse_diff_hunk([b"@@ -1 +1 @@", b"-a", b"+x"], 0, 1)
  let (second, _) = parse_diff_hunk([b"@@ -2 +2 @@", b"-b", b"+y"], 0, 2)
  let ranges = validate_diff_hunks("d", "a.mbt", b"x\ny\n", [first, second])
  assert_eq(ranges.length(), 1)
  assert_true(
    (Some(validate_diff_hunks("d", "a.mbt", b"x\ny\n", [first, first])) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(validate_diff_hunks("d", "a.mbt", b"x\ny\n", [second, first])) catch {
      _ => None
    })
    is None,
  )
  let (deletion, _) = parse_diff_hunk([b"@@ -3 +3,0 @@", b"-gone"], 0, 1)
  assert_true(
    (Some(validate_diff_hunks("d", "a.mbt", b"x\ny\n", [deletion])) catch {
      _ => None
    })
    is None,
  )
}

///|
test "context-only hunks are malformed even when both counts match" {
  assert_true(
    (Some(parse_diff_hunk([b"@@ -1 +1 @@", b" same"], 0, 1)) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(
      parse_diff_sections(
        b"--- a/file.mbt\n+++ b/file.mbt\n@@ -1 +1 @@\n same\n",
      ),
    ) catch {
      _ => None
    })
    is None,
  )
  // A deletion-only hunk is a real edit even though it selects no new lines.
  let (deletion, _) = parse_diff_hunk([b"@@ -1 +0,0 @@", b"-gone"], 0, 1)
  assert_true(deletion.lines.is_empty())
}

///|
test "hunk omitted lines must agree before and between edits" {
  for
    patch in [
      b"--- a/x.mbt\n+++ b/x.mbt\n@@ -999 +2 @@\n-old\n+new\n", b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1 +1 @@\n-a\n+b\n@@ -3 +4 @@\n-c\n+d\n",
    ] {
    assert_true((Some(parse_diff_sections(patch)) catch { _ => None }) is None)
  }
  // One inserted line shifts subsequent coordinates, not the unchanged gaps.
  let valid = b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1,0 +2 @@\n+inserted\n@@ -3 +4 @@\n-old\n+new\n"
  let sections = parse_diff_sections(valid)
  assert_eq(sections[0].hunks.length(), 2)
}

///|
test "zero-count hunks cannot skip beyond a declared old or new EOF" {
  for
    patch in [
      b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n@@ -2,0 +3 @@\n+c\n",
      b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n@@ -3 +2,0 @@\n-c\n",
    ] {
    assert_true((Some(parse_diff_sections(patch)) catch { _ => None }) is None)
  }
  let insertion = parse_diff_sections(
    b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n@@ -1,0 +2 @@\n+c\n",
  )
  assert_eq(insertion[0].hunks.length(), 2)
  let deletion = parse_diff_sections(
    b"--- a/x.mbt\n+++ b/x.mbt\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n@@ -2 +1,0 @@\n-c\n",
  )
  assert_eq(deletion[0].hunks.length(), 2)
}
