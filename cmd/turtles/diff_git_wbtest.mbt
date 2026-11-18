///|
test "Git metadata parses modes, rename and index records" {
  let (metadata, next) = diff_git_metadata(
    [
      b"similarity index 87%", b"rename from old name.mbt", b"rename to new name.mbt",
      b"index 1234567..abcdef0 100644", b"--- a/old name.mbt",
    ],
    0,
  )
  assert_eq(next, 4)
  assert_eq(metadata.rename_from, Some("old name.mbt"))
  assert_eq(metadata.rename_to, Some("new name.mbt"))
  assert_eq(metadata.old_mode, Some("100644"))
  assert_eq(metadata.new_mode, Some("100644"))
  let (added, _) = diff_git_metadata(
    [b"new file mode 100644", b"index 0000000..abcdef0"],
    0,
  )
  assert_true(added.added)
}

///|
test "Git metadata rejects inconsistent or unsafe records" {
  for
    bad in [
      [b"rename from old"],
      [b"new file mode 100644", b"deleted file mode 100644"],
      [b"old mode 100644"],
      [b"old mode 100644", b"new file mode 100644"],
      [b"new mode 100644", b"deleted file mode 100644"],
      [b"index 1234567..abcdef0 100644", b"old mode 100755"],
      [b"similarity index 101%"],
      [b"rename from ../outside", b"rename to safe"],
      [b"index invalid"],
    ] {
    assert_true((Some(diff_git_metadata(bad, 0)) catch { _ => None }) is None)
  }
}

///|
test "Git sections validate header agreement and source modes" {
  let (section, next) = parse_git_diff_section(
    diff_patch_lines(
      b"diff --git a/a.mbt b/a.mbt\nindex 1234567..abcdef0 100644\n--- a/a.mbt\n+++ b/a.mbt\n@@ -1 +1 @@\n-old\n+new\n",
    ),
    0,
  )
  assert_eq(next, 7)
  assert_eq(section.new_path, "a.mbt")
  assert_eq(
    validate_diff_hunks("d", section.new_path, b"new\n", section.hunks).length(),
    1,
  )
  let (rename, _) = parse_git_diff_section(
    diff_patch_lines(
      b"diff --git a/old name.mbt b/new name.mbt\nsimilarity index 100%\nrename from old name.mbt\nrename to new name.mbt\n",
    ),
    0,
  )
  assert_eq(
    (rename.old_path, rename.new_path),
    ("old name.mbt", "new name.mbt"),
  )
  for
    bad in [
      b"diff --git a/a.mbt b/b.mbt\n--- a/a.mbt\n+++ b/c.mbt\n@@ -1 +1 @@\n-a\n+b\n",
      b"diff --git a/a.mbt b/a.mbt\nnew file mode 120000\n", b"diff --git a/a.mbt b/a.mbt\nindex 1234567..abcdef0 100644\n",
    ] {
    assert_true(
      (Some(parse_git_diff_section(diff_patch_lines(bad), 0)) catch {
        _ => None
      })
      is None,
    )
  }
}

///|
test "Git binary sections are framed and reject MoonBit sources" {
  let (section, next) = parse_git_diff_section(
    diff_patch_lines(
      b"diff --git a/a.bin b/a.bin\nindex 1234567..abcdef0 100644\nGIT binary patch\nliteral 3\nabc\n\n",
    ),
    0,
  )
  assert_true(section.binary)
  assert_eq(next, 6)
  assert_true(
    (Some(
      parse_git_diff_section(
        diff_patch_lines(
          b"diff --git a/a.mbt b/a.mbt\nBinary files a/a.mbt and b/a.mbt differ\n",
        ),
        0,
      ),
    ) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(
      parse_git_diff_section(
        diff_patch_lines(
          b"diff --git a/a.bin b/a.bin\nGIT binary patch\nliteral 3\n",
        ),
        0,
      ),
    ) catch {
      _ => None
    })
    is None,
  )
}

///|
test "Git additions, deletions and mode-only sections keep their scope" {
  let added = b"diff --git a/a.mbt b/a.mbt\nnew file mode 100644\nindex 0000000..abcdef0\n--- /dev/null\n+++ b/a.mbt\n@@ -0,0 +1 @@\n+true\n"
  let (addition, _) = parse_git_diff_section(diff_patch_lines(added), 0)
  assert_eq(addition.old_path, "/dev/null")
  assert_eq(addition.new_path, "a.mbt")
  let deleted = b"diff --git a/a.mbt b/a.mbt\ndeleted file mode 100644\nindex 1234567..0000000\n--- a/a.mbt\n+++ /dev/null\n@@ -1 +0,0 @@\n-true\n"
  let (deletion, _) = parse_git_diff_section(diff_patch_lines(deleted), 0)
  assert_eq(deletion.new_path, "/dev/null")
  let mode = b"diff --git a/a.mbt b/a.mbt\nold mode 100644\nnew mode 100755\n"
  let (mode_only, _) = parse_git_diff_section(diff_patch_lines(mode), 0)
  assert_true(mode_only.hunks.is_empty())
  assert_false(mode_only.binary)
}

///|
test "prefixless Git additions and deletions retain literal prefix directories" {
  let added = b"diff --git b/calc.mbt b/calc.mbt\nnew file mode 100644\nindex 0000000..abcdef0\n--- /dev/null\n+++ b/calc.mbt\n@@ -0,0 +1 @@\n+true\n"
  let (addition, _) = parse_git_diff_section(diff_patch_lines(added), 0)
  assert_eq((addition.old_path, addition.new_path), ("/dev/null", "b/calc.mbt"))
  assert_eq(
    validate_diff_hunks("patch", addition.new_path, b"true\n", addition.hunks).length(),
    1,
  )
  let deleted = b"diff --git a/calc.mbt a/calc.mbt\ndeleted file mode 100644\nindex abcdef0..0000000\n--- a/calc.mbt\n+++ /dev/null\n@@ -1 +0,0 @@\n-true\n"
  let (deletion, _) = parse_git_diff_section(diff_patch_lines(deleted), 0)
  assert_eq((deletion.old_path, deletion.new_path), ("a/calc.mbt", "/dev/null"))
}

///|
test "Git text hunks require file headers even when represented bytes match" {
  let missing = b"diff --git a/calc.mbt b/calc.mbt\nindex 1234567..abcdef0 100644\n@@ -1 +1 @@\n-false\n+true\n"
  assert_true((Some(parse_diff_sections(missing)) catch { _ => None }) is None)
}

///|
test "overlapping binary summary markers are rejected without slicing abort" {
  assert_false(
    diff_binary_header_matches(b"Binary files differ", "x.bin", "x.bin"),
  )
  assert_false(
    diff_binary_header_matches(b"Binary files  differ", "x.bin", "x.bin"),
  )
  let malformed = b"diff --git a/x.bin b/x.bin\nBinary files differ\n"
  assert_true(
    (Some(parse_diff_sections(malformed)) catch { _ => None }) is None,
  )
}

///|
test "Git 100 percent rename similarity permits reordered text hunks" {
  let patch = b"diff --git a/old.mbt b/new.mbt\nsimilarity index 100%\nrename from old.mbt\nrename to new.mbt\nindex 1234567..abcdef0 100644\n--- a/old.mbt\n+++ b/new.mbt\n@@ -1,2 +1,2 @@\n-one\n two\n+one\n"
  let sections = parse_diff_sections(patch)
  assert_eq(sections[0].new_path, "new.mbt")
  let ranges = validate_diff_hunks(
    "patch",
    "new.mbt",
    b"two\none\n",
    sections[0].hunks,
  )
  assert_eq(ranges.length(), 1)
  assert_eq((ranges[0].start, ranges[0].end), (4, 8))
}

///|
test "prefixless rename and binary addition retain a and b directories" {
  for
    patch in [
      b"diff --git a/file.mbt b/file.mbt\nsimilarity index 100%\nrename from a/file.mbt\nrename to b/file.mbt\n",
      b"diff --git a/file.mbt b/file.mbt\nsimilarity index 80%\nrename from a/file.mbt\nrename to b/file.mbt\nindex 1234567..abcdef0 100644\n--- a/file.mbt\n+++ b/file.mbt\n@@ -1 +1 @@\n-old\n+new\n",
      b"diff --git a/a/file.mbt b/b/file.mbt\nsimilarity index 80%\nrename from a/file.mbt\nrename to b/file.mbt\nindex 1234567..abcdef0 100644\n--- a/a/file.mbt\n+++ b/b/file.mbt\n@@ -1 +1 @@\n-old\n+new\n",
    ] {
    let sections = parse_diff_sections(patch)
    assert_eq(
      (sections[0].old_path, sections[0].new_path),
      ("a/file.mbt", "b/file.mbt"),
    )
  }
  let binary = b"diff --git b/image.bin b/image.bin\nnew file mode 100644\nindex 0000000..abcdef0\nBinary files /dev/null and b/image.bin differ\n"
  let sections = parse_diff_sections(binary)
  assert_true(sections[0].binary)
  assert_eq(
    (sections[0].old_path, sections[0].new_path),
    ("/dev/null", "b/image.bin"),
  )
  let prefixed = b"diff --git a/b/image.bin b/b/image.bin\nnew file mode 100644\nindex 0000000..abcdef0\nBinary files /dev/null and b/b/image.bin differ\n"
  let prefixed_sections = parse_diff_sections(prefixed)
  assert_eq(prefixed_sections[0].new_path, "b/image.bin")
}
