///|
test "plain unified sections retain paths and hunks" {
  let sections = parse_unified_sections(
    b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+new\n--- /dev/null\n+++ b/new file.mbt\n@@ -0,0 +1 @@\n+hello\n",
  )
  assert_eq(sections.length(), 2)
  assert_eq(
    (sections[0].old_path, sections[0].new_path),
    ("a/a.mbt", "b/a.mbt"),
  )
  assert_eq(
    (sections[1].old_path, sections[1].new_path),
    ("/dev/null", "b/new file.mbt"),
  )
  assert_eq(
    validate_diff_hunks("d", "a.mbt", b"new\n", sections[0].hunks).length(),
    1,
  )
  assert_eq(parse_unified_sections(b"").length(), 0)
}

///|
test "plain unified sections reject malformed and duplicate inputs" {
  for
    bad in [
      b"not a diff\n", b"--- a/a.mbt\n", b"--- a/a.mbt\n+++ b/a.mbt\n", b"--- /dev/null\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+new\n",
      b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-a\n+b\n--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-a\n+b\n",
    ] {
    assert_true((Some(parse_unified_sections(bad)) catch { _ => None }) is None)
  }
}

///|
test "CRLF patch framing and source CRLF retain correct source bytes" {
  let sections = parse_unified_sections(
    b"--- a/a.mbt\r\n+++ b/a.mbt\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n",
  )
  let ranges = validate_diff_hunks("d", "a.mbt", b"b\r\n", sections[0].hunks)
  assert_eq((ranges[0].start, ranges[0].end), (0, 3))
}

///|
test "mixed Git and unified sections reject duplicates and unrecognized data" {
  let raw = b"diff --git a/a.mbt b/a.mbt\nindex 1234567..abcdef0 100644\n--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-a\n+b\n--- a/b.mbt\n+++ b/b.mbt\n@@ -1 +1 @@\n-a\n+c\n"
  let sections = parse_diff_sections(raw)
  assert_eq(sections.length(), 2)
  assert_eq(sections[1].new_path, "b/b.mbt")
  assert_true(
    (Some(parse_diff_sections(b"diff --cc conflict.mbt\n")) catch { _ => None })
    is None,
  )
  assert_true(
    (Some(
      parse_diff_sections(
        b"diff --git a/a.mbt b/a.mbt\nold mode 100644\nnew mode 100755\n--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-a\n+b\n--- a.mbt\n+++ a.mbt\n@@ -1 +1 @@\n-a\n+b\n",
      ),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "Git binary payload is structurally validated without inflation" {
  let sections = parse_diff_sections(
    b"diff --git a/a.bin b/a.bin\nGIT binary patch\nliteral 1\nA00000\n\n",
  )
  assert_eq(sections.length(), 1)
  assert_true(sections[0].binary)
}

///|
test "unterminated patch data cannot stand in for a newline marker" {
  let bad = b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+new"
  assert_true((Some(parse_diff_sections(bad)) catch { _ => None }) is None)
  let marked = b"--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file"
  let sections = parse_diff_sections(marked)
  assert_eq(
    validate_diff_hunks("d", "a.mbt", b"new", sections[0].hunks).length(),
    1,
  )
}

///|
test "patch physical line budget is checked before line copies" {
  assert_eq(diff_patch_lines(b"a\nb\nc\n", line_limit=3), [b"a", b"b", b"c"])
  assert_eq(diff_patch_lines(b"a\nb\nc", line_limit=3), [b"a", b"b", b"c"])
  assert_eq(diff_patch_lines(b"", line_limit=0), [])
  for raw in [b"a\nb\nc\nd", b"a\nb\nc\nd\n"] {
    assert_true(
      (Some(diff_patch_lines(raw, line_limit=3)) catch { _ => None }) is None,
    )
  }
  assert_true(
    (Some(diff_patch_lines(b"x", line_limit=0)) catch { _ => None }) is None,
  )
}

///|
test "absent sides require zero start as well as zero count in both formats" {
  for
    patch in [
      b"--- /dev/null\n+++ b/a.mbt\n@@ -2,0 +3 @@\n+new\n", b"--- a/a.mbt\n+++ /dev/null\n@@ -3 +2,0 @@\n-old\n",
    ] {
    assert_true(
      (Some(parse_unified_sections(patch)) catch { _ => None }) is None,
    )
    assert_true((Some(parse_diff_sections(patch)) catch { _ => None }) is None)
  }
  for
    patch in [
      b"diff --git a/a.mbt b/a.mbt\nnew file mode 100644\n--- /dev/null\n+++ b/a.mbt\n@@ -2,0 +3 @@\n+new\n",
      b"diff --git a/a.mbt b/a.mbt\ndeleted file mode 100644\n--- a/a.mbt\n+++ /dev/null\n@@ -3 +2,0 @@\n-old\n",
    ] {
    assert_true((Some(parse_diff_sections(patch)) catch { _ => None }) is None)
  }
}

///|
test "standalone one sided unified paths retain literal prefix directories" {
  let added = parse_diff_sections(
    b"--- /dev/null\n+++ b/calc.mbt\n@@ -0,0 +1 @@\n+true\n",
  )
  assert_eq(added[0].new_path, "b/calc.mbt")
  let deleted = parse_diff_sections(
    b"--- a/calc.mbt\n+++ /dev/null\n@@ -1 +0,0 @@\n-true\n",
  )
  assert_eq(deleted[0].old_path, "a/calc.mbt")
}
