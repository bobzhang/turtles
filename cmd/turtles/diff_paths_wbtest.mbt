///|
test "decode unified header paths and quoted Git octets" {
  assert_eq(diff_header_path(b"file name.mbt\t2026-01-01"), "file name.mbt")
  assert_eq(diff_header_path(b"\"b/space name.mbt\""), "b/space name.mbt")
  assert_eq(diff_header_path(b"\"b/\\343\\201\\202.mbt\""), "b/あ.mbt")
  assert_eq(diff_header_path(b"\"b/quote\\\".mbt\"\tdate"), "b/quote\".mbt")
  assert_eq(diff_normalize_paths("a/x.mbt", "b/x.mbt"), ("x.mbt", "x.mbt"))
  assert_eq(
    diff_normalize_paths("/dev/null", "b/new.mbt"),
    ("/dev/null", "new.mbt"),
  )
  assert_eq(diff_normalize_paths("a/x.mbt", "x.mbt"), ("a/x.mbt", "x.mbt"))
}

///|
test "reject malformed and unsafe diff paths" {
  for
    bad in [
      b"\"unterminated", b"\"x\\777\"", b"\"x\\12\"", b"\"x\\q\"", b"\"x\" trailing",
      b"\"\\377\"",
    ] {
    assert_true((Some(diff_header_path(bad)) catch { _ => None }) is None)
  }
  for
    bad in [
      "", "/abs", "../x", "x/../y", "x//y", "x/./y", "C:/x", "x\\y", "x\ny",
    ] {
    assert_true((Some(validate_diff_path(bad)) catch { _ => None }) is None)
  }
  assert_true(
    (Some(diff_normalize_paths("a//dev/null", "b/safe")) catch { _ => None })
    is None,
  )
  assert_true(
    (Some(diff_normalize_paths("/dev/null", "/dev/null")) catch { _ => None })
    is None,
  )
}

///|
test "Git headers use both file header hints to disambiguate spaces" {
  assert_eq(
    diff_git_header_paths(
      b"a/one name.mbt b/one name.mbt",
      Some("one name.mbt"),
      Some("one name.mbt"),
    ),
    ("one name.mbt", "one name.mbt"),
  )
  assert_eq(
    diff_git_header_paths(
      b"\"a/old\\040name.mbt\" \"b/new\\040name.mbt\"",
      Some("old name.mbt"),
      Some("new name.mbt"),
    ),
    ("old name.mbt", "new name.mbt"),
  )
  assert_eq(
    diff_git_header_paths(
      b"a/new.mbt b/new.mbt",
      Some("/dev/null"),
      Some("new.mbt"),
    ),
    ("new.mbt", "new.mbt"),
  )
  assert_eq(
    diff_git_header_paths(b"a/file.mbt b/file.mbt", None, None),
    ("file.mbt", "file.mbt"),
  )
  assert_true(
    (Some(
      diff_git_header_paths(
        b"a/one.mbt b/two.mbt",
        Some("one.mbt"),
        Some("wrong.mbt"),
      ),
    ) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(diff_git_header_paths(b"a/../bad b/../bad", None, None)) catch {
      _ => None
    })
    is None,
  )
}

///|
test "Git header candidate boundaries reject short and oversized hints" {
  assert_true(
    (Some(diff_git_header_paths(b"x", Some("a much longer path"), Some("x"))) catch {
      _ => None
    })
    is None,
  )
  assert_true(
    (Some(diff_git_header_paths(b"\"unterminated", None, None)) catch {
      _ => None
    })
    is None,
  )
  assert_eq(
    diff_git_header_paths(b"same \"same\"", None, None),
    ("same", "same"),
  )
}

///|
test "Git path identity retains raw pair and section prefix mode" {
  let prefixed = diff_git_header_identity(
    b"a/file b/file",
    Some("file"),
    Some("file"),
  )
  assert_true(prefixed.prefixed)
  assert_eq((prefixed.raw_old, prefixed.raw_new), ("a/file", "b/file"))
  let literal = diff_git_header_identity(
    b"a/file b/file",
    Some("a/file"),
    Some("b/file"),
  )
  assert_false(literal.prefixed)
  assert_eq((literal.old_path, literal.new_path), ("a/file", "b/file"))
}
