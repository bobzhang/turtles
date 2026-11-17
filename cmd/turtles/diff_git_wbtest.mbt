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
