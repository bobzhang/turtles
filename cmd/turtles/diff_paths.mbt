///|
/// Decode the path portion of a unified-diff file header. Unquoted headers
/// use only a tab, never a space, to introduce a timestamp. Quoted Git paths
/// are decoded as bytes before validating UTF-8.
fn diff_header_path(input : Bytes) -> String raise {
  let out = @buffer.Buffer()
  if input.length() > 0 && input[0] == b'"' {
    let mut i = 1
    let mut closed = false
    while i < input.length() {
      let byte = input[i]
      if byte == b'"' {
        closed = true
        i = i + 1
        break
      }
      if byte != b'\\' {
        out.write_byte(byte)
        i = i + 1
        continue
      }
      i = i + 1
      guard i < input.length() else { fail("unterminated path escape") }
      let escaped = input[i]
      if escaped >= b'0' && escaped <= b'7' {
        guard i + 2 < input.length() &&
          input[i + 1] >= b'0' &&
          input[i + 1] <= b'7' &&
          input[i + 2] >= b'0' &&
          input[i + 2] <= b'7' else {
          fail("invalid octal path escape")
        }
        let value = (escaped.to_int() - 48) * 64 +
          (input[i + 1].to_int() - 48) * 8 +
          input[i + 2].to_int() -
          48
        guard value <= 255 else { fail("octal path escape exceeds one byte") }
        out.write_byte(value.to_byte())
        i = i + 3
        continue
      }
      let value : Byte = match escaped {
        b'\\' => b'\\'
        b'"' => b'"'
        b'a' => 7
        b'b' => 8
        b't' => 9
        b'n' => 10
        b'v' => 11
        b'f' => 12
        b'r' => 13
        _ => fail("invalid path escape")
      }
      out.write_byte(value)
      i = i + 1
    }
    guard closed else { fail("unterminated quoted path") }
    guard i == input.length() || input[i] == b'\t' else {
      fail("unexpected text after quoted path")
    }
  } else {
    for byte in input {
      if byte == b'\t' {
        break
      }
      out.write_byte(byte)
    }
  }
  let path = @utf8.decode(out.to_bytes()) catch {
    _ => fail("path is not UTF-8")
  }
  guard path != "" else { fail("empty diff path") }
  path
}

///|
/// Restrict diff paths before joining them to the module directory. The
/// /dev/null sentinel is handled separately and is never passed here.
fn validate_diff_path(path : String) -> Unit raise {
  let bytes = @utf8.encode(path)
  guard bytes.length() > 0 && bytes[0] != b'/' else {
    fail("absolute or empty diff path: \{path}")
  }
  if bytes.length() >= 2 && bytes[1] == b':' {
    fail("drive-qualified diff path: \{path}")
  }
  for ch in path {
    let code = ch.to_int()
    guard ch != '\\' && code >= 32 && !(code >= 127 && code <= 159) else {
      fail("control character or backslash in diff path")
    }
  }
  for component in path.split("/") {
    guard component != "" && component != "." && component != ".." else {
      fail("unsafe diff path: \{path}")
    }
  }
}

///|
/// Strip the conventional Git prefixes only when the pair proves they are
/// present. A one-sided deletion or addition has only its respective prefix.
fn diff_normalize_paths(
  old_path : String,
  new_path : String,
) -> (String, String) raise {
  guard old_path != "/dev/null" || new_path != "/dev/null" else {
    fail("both diff paths are /dev/null")
  }
  if old_path != "/dev/null" {
    validate_diff_path(old_path)
  }
  if new_path != "/dev/null" {
    validate_diff_path(new_path)
  }
  let (old_path, new_path) = if old_path == "/dev/null" &&
    new_path.has_prefix("b/") {
    (old_path, new_path[2:].to_owned())
  } else if new_path == "/dev/null" && old_path.has_prefix("a/") {
    (old_path[2:].to_owned(), new_path)
  } else if old_path.has_prefix("a/") && new_path.has_prefix("b/") {
    (old_path[2:].to_owned(), new_path[2:].to_owned())
  } else {
    (old_path, new_path)
  }
  if old_path != "/dev/null" {
    validate_diff_path(old_path)
  }
  if new_path != "/dev/null" {
    validate_diff_path(new_path)
  }
  (old_path, new_path)
}

///|
/// Resolve the two paths in a `diff --git` header. Unquoted Git paths may
/// contain spaces, so examine every separator and require a unique pair that
/// agrees with the file headers or rename metadata. When no hints exist (a
/// mode-only or binary section), only an unchanged path pair is accepted.
fn diff_git_header_paths(
  input : Bytes,
  old_hint : String?,
  new_hint : String?,
) -> (String, String) raise {
  for byte in input {
    guard byte != b'\t' else { fail("tab in Git diff header") }
  }
  // There are at most two possible lengths for an unquoted old path:
  // the hinted path itself, or that path with the conventional a/ prefix.
  // For unchanged paths without hints both raw paths have equal length;
  // quoted tokens have an explicit boundary. This avoids quadratic work on
  // long headers containing many spaces.
  let separators : Array[Int32] = []
  if input.length() > 0 && input[0] == b'"' {
    let mut i = 1
    while i < input.length() {
      if input[i] == b'\\' {
        i = i + 2
        continue
      }
      if input[i] == b'"' {
        separators.push(i + 1)
        break
      }
      i = i + 1
    }
  } else {
    let hint = match (old_hint, new_hint) {
      (Some("/dev/null"), Some(value)) => Some(value)
      (Some(value), _) => Some(value)
      _ => None
    }
    match hint {
      Some(value) => {
        let size = @utf8.encode(value).length()
        separators.push(size)
        separators.push(size + 2)
      }
      None => {
        if input.length() % 2 == 1 {
          separators.push((input.length() - 1) / 2)
        }
        if input.length() > 1 && input[input.length() - 1] == b'"' {
          let mut i = input.length() - 2
          while i >= 0 {
            if input[i] == b'"' {
              let mut slash_count = 0
              let mut j = i - 1
              while j >= 0 && input[j] == b'\\' {
                slash_count = slash_count + 1
                j = j - 1
              }
              if slash_count % 2 == 0 {
                if i > 0 && input[i - 1] == b' ' && !separators.contains(i - 1) {
                  separators.push(i - 1)
                }
                break
              }
              i = j
            } else {
              i = i - 1
            }
          }
        }
      }
    }
  }
  let mut candidate : (String, String)? = None
  for i in separators {
    if i <= 0 || i + 1 >= input.length() || input[i] != b' ' {
      continue
    }
    let pair = Some(
      (
        diff_header_path(input[:i].to_owned()),
        diff_header_path(input[i + 1:].to_owned()),
      ),
    ) catch {
      _ => None
    }
    guard pair is Some((raw_old, raw_new)) else { continue }
    guard raw_old != "/dev/null" && raw_new != "/dev/null" else { continue }
    let normalized = Some(diff_normalize_paths(raw_old, raw_new)) catch {
      _ => None
    }
    guard normalized is Some(normalized_paths) else { continue }
    let interpretations = [normalized_paths]
    // Rename/file metadata can prove that a/ and b/ are literal directories.
    // Without hints retain conventional Git prefix handling.
    if old_hint is Some(_) &&
      new_hint is Some(_) &&
      normalized_paths != (raw_old, raw_new) {
      interpretations.push((raw_old, raw_new))
    }
    for (old_path, new_path) in interpretations {
      let matches = match (old_hint, new_hint) {
        (Some("/dev/null"), Some(expected)) =>
          old_path == expected && new_path == expected
        (Some(expected), Some("/dev/null")) =>
          old_path == expected && new_path == expected
        (Some(old_expected), Some(new_expected)) =>
          old_path == old_expected && new_path == new_expected
        (None, None) => old_path == new_path
        _ => false
      }
      if matches {
        guard candidate is None else { fail("ambiguous Git diff header paths") }
        candidate = Some((old_path, new_path))
      }
    }
  }
  guard candidate is Some(paths) else {
    fail("Git diff header paths do not match section")
  }
  paths
}
