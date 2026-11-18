///|
struct DiffGitMetadata {
  mut old_mode : String?
  mut new_mode : String?
  mut added : Bool
  mut deleted : Bool
  mut rename_from : String?
  mut rename_to : String?
  mut similarity : Int32?
  mut index_seen : Bool
}

///|
fn diff_mode(bytes : Bytes) -> String raise {
  guard bytes.length() == 6 else { fail("invalid Git file mode") }
  for byte in bytes {
    guard byte >= b'0' && byte <= b'7' else { fail("invalid Git file mode") }
  }
  let mode = @utf8.decode(bytes)
  guard mode == "100644" ||
    mode == "100755" ||
    mode == "120000" ||
    mode == "160000" else {
    fail("unsupported Git file mode")
  }
  mode
}

///|
fn diff_metadata_path(bytes : Bytes) -> String raise {
  for byte in bytes {
    guard byte != b'\t' else { fail("tab in Git metadata path") }
  }
  let path = diff_header_path(bytes)
  validate_diff_path(path)
  path
}

///|
fn diff_is_hex(bytes : BytesView) -> Bool {
  if bytes.length() < 4 || bytes.length() > 64 {
    return false
  }
  for byte in bytes {
    if !(byte >= b'0' && byte <= b'9') &&
      !(byte >= b'a' && byte <= b'f') &&
      !(byte >= b'A' && byte <= b'F') {
      return false
    }
  }
  true
}

///|
/// Validate the index metadata shape; object IDs are not evidence that the
/// working tree matches either revision.
fn diff_index_mode(line : Bytes) -> String? raise {
  let mut delimiter = -1
  let mut space = -1
  for i = 0; i < line.length(); i = i + 1 {
    if i + 1 < line.length() && line[i] == b'.' && line[i + 1] == b'.' {
      guard delimiter < 0 else { fail("invalid Git index metadata") }
      delimiter = i
    }
    if line[i] == b' ' {
      guard space < 0 else { fail("invalid Git index metadata") }
      space = i
    }
  }
  let end = if space < 0 { line.length() } else { space }
  guard delimiter > 0 &&
    delimiter + 2 < end &&
    diff_is_hex(line[:delimiter]) &&
    diff_is_hex(line[delimiter + 2:end]) else {
    fail("invalid Git index metadata")
  }
  if space < 0 {
    None
  } else {
    Some(diff_mode(line[space + 1:].to_owned()))
  }
}

///|
/// Consume recognized Git metadata, rejecting duplicates and malformed
/// values. Path-pair and mode consistency are checked after headers are read.
fn diff_git_metadata(
  lines : Array[Bytes],
  start : Int32,
) -> (DiffGitMetadata, Int32) raise {
  let info : DiffGitMetadata = {
    old_mode: None,
    new_mode: None,
    added: false,
    deleted: false,
    rename_from: None,
    rename_to: None,
    similarity: None,
    index_seen: false,
  }
  let mut i = start
  while i < lines.length() {
    let line = lines[i]
    if line.length() >= 13 && line[:13] == b"new file mode" {
      guard line.length() > 14 &&
        line[13] == b' ' &&
        info.new_mode is None &&
        info.old_mode is None &&
        !info.deleted else {
        fail("invalid or duplicate new file mode")
      }
      info.new_mode = Some(diff_mode(line[14:].to_owned()))
      info.added = true
    } else if line.length() >= 17 && line[:17] == b"deleted file mode" {
      guard line.length() > 18 &&
        line[17] == b' ' &&
        info.old_mode is None &&
        info.new_mode is None &&
        !info.added else {
        fail("invalid or duplicate deleted file mode")
      }
      info.old_mode = Some(diff_mode(line[18:].to_owned()))
      info.deleted = true
    } else if line.length() >= 9 && line[:9] == b"old mode " {
      guard info.old_mode is None && !info.added && !info.deleted else {
        fail("invalid or duplicate old mode")
      }
      info.old_mode = Some(diff_mode(line[9:].to_owned()))
    } else if line.length() >= 9 && line[:9] == b"new mode " {
      guard info.new_mode is None && !info.added && !info.deleted else {
        fail("invalid or duplicate new mode")
      }
      info.new_mode = Some(diff_mode(line[9:].to_owned()))
    } else if line.length() >= 6 && line[:6] == b"index " {
      guard !info.index_seen else { fail("duplicate Git index metadata") }
      info.index_seen = true
      let mode = diff_index_mode(line[6:].to_owned())
      match mode {
        Some(value) => {
          guard info.old_mode is None &&
            info.new_mode is None &&
            !info.added &&
            !info.deleted else {
            fail("index mode conflicts with file modes")
          }
          info.old_mode = Some(value)
          info.new_mode = Some(value)
        }
        None => ()
      }
    } else if line.length() >= 12 && line[:12] == b"rename from " {
      guard info.rename_from is None else { fail("duplicate rename from") }
      info.rename_from = Some(diff_metadata_path(line[12:].to_owned()))
    } else if line.length() >= 10 && line[:10] == b"rename to " {
      guard info.rename_to is None else { fail("duplicate rename to") }
      info.rename_to = Some(diff_metadata_path(line[10:].to_owned()))
    } else if line.length() >= 17 && line[:17] == b"similarity index " {
      guard info.similarity is None else { fail("duplicate similarity index") }
      let number = line[17:].to_owned()
      let (value, end) = diff_decimal(number, 0)
      guard value <= 100 && end + 1 == number.length() && number[end] == b'%' else {
        fail("invalid similarity index")
      }
      info.similarity = Some(value)
    } else {
      break
    }
    i = i + 1
  }
  guard (info.rename_from is Some(_)) == (info.rename_to is Some(_)) else {
    fail("incomplete rename metadata")
  }
  guard info.similarity is None || info.rename_from is Some(_) else {
    fail("similarity index lacks rename metadata")
  }
  guard !(info.added || info.deleted) || info.rename_from is None else {
    fail("rename conflicts with file creation or deletion")
  }
  if !info.added && !info.deleted {
    guard (info.old_mode is Some(_)) == (info.new_mode is Some(_)) else {
      fail("incomplete mode change")
    }
  }
  (info, i)
}

///|
fn diff_starts(line : Bytes, prefix : Bytes) -> Bool {
  line.length() >= prefix.length() && line[:prefix.length()] == prefix[:]
}

///|
fn diff_ends(line : Bytes, suffix : Bytes) -> Bool {
  line.length() >= suffix.length() &&
  line[line.length() - suffix.length():] == suffix[:]
}

///|
fn diff_binary_header_matches(
  line : Bytes,
  expected_old : String,
  expected_new : String,
) -> Bool {
  if line.length() < 20 ||
    !diff_starts(line, b"Binary files ") ||
    !diff_ends(line, b" differ") {
    return false
  }
  let body = line[13:line.length() - 7].to_owned()
  let positions : Array[Int32] = []
  if body.length() > 0 && body[0] == b'"' {
    let mut i = 1
    while i < body.length() {
      if body[i] == b'\\' {
        i = i + 2
        continue
      }
      if body[i] == b'"' {
        positions.push(i + 1)
        break
      }
      i = i + 1
    }
  } else {
    let size = @utf8.encode(expected_old).length()
    positions.push(size)
    if expected_old != "/dev/null" {
      positions.push(size + 2)
    }
  }
  let mut matches = 0
  for i in positions {
    if i <= 0 || i + 5 >= body.length() || body[i:i + 5] != b" and " {
      continue
    }
    let pair = Some(
      (
        diff_header_path(body[:i].to_owned()),
        diff_header_path(body[i + 5:].to_owned()),
      ),
    ) catch {
      _ => None
    }
    guard pair is Some((old_raw, new_raw)) else { continue }
    let normalized = Some(diff_normalize_paths(old_raw, new_raw)) catch {
      _ => None
    }
    if normalized == Some((expected_old, expected_new)) {
      matches = matches + 1
    }
  }
  matches == 1
}

///|
/// Validate the record framing of a Git binary patch while leaving payload
/// bytes opaque. Git emits one or two literal/delta records separated by an
/// empty line; a record must contain at least one payload line.
fn diff_binary_records(lines : Array[Bytes], start : Int32) -> Int32 raise {
  let mut i = start
  let mut records = 0
  while i < lines.length() &&
        (diff_starts(lines[i], b"literal ") || diff_starts(lines[i], b"delta ")) {
    let header = lines[i]
    let prefix = if diff_starts(header, b"literal ") { 8 } else { 6 }
    let number = header[prefix:].to_owned()
    let (_, end) = diff_decimal(number, 0)
    guard end == number.length() else { fail("invalid binary patch record") }
    records = records + 1
    guard records <= 2 else { fail("too many binary patch records") }
    i = i + 1
    let first_payload = i
    while i < lines.length() && !lines[i].is_empty() {
      guard !diff_starts(lines[i], b"diff --git ") else {
        fail("unterminated binary patch record")
      }
      i = i + 1
    }
    guard i > first_payload && i < lines.length() else {
      fail("incomplete binary patch record")
    }
    i = i + 1
  }
  guard records > 0 else { fail("missing binary patch record") }
  i
}

///|
/// Parse a single Git section after the enclosing parser has split patch
/// lines. Unrecognized trailing data is left for the enclosing parser to
/// reject instead of being interpreted as an empty selection.
fn parse_git_diff_section(
  lines : Array[Bytes],
  start : Int32,
) -> (DiffSection, Int32) raise {
  guard start < lines.length() && diff_starts(lines[start], b"diff --git ") else {
    fail("missing Git diff header")
  }
  let git_paths = lines[start][11:].to_owned()
  let (meta, after_metadata) = diff_git_metadata(lines, start + 1)
  let mut i = after_metadata
  let mut has_headers = false
  let mut old_path = ""
  let mut new_path = ""
  if i < lines.length() && diff_starts(lines[i], b"--- ") {
    let old_raw = diff_header_path(lines[i][4:].to_owned())
    i = i + 1
    guard i < lines.length() && diff_starts(lines[i], b"+++ ") else {
      fail("missing Git new-side header")
    }
    let new_raw = diff_header_path(lines[i][4:].to_owned())
    // One-sided paths may begin with literal a/ or b/ directories in a
    // --no-prefix patch. Let the Git pair prove that spelling before stripping.
    let raw_matches = if old_raw == "/dev/null" || new_raw == "/dev/null" {
      (Some(diff_git_header_paths(git_paths, Some(old_raw), Some(new_raw))) catch {
        _ => None
      })
      is Some(_)
    } else {
      false
    }
    let normalized = if raw_matches {
      (old_raw, new_raw)
    } else {
      diff_normalize_paths(old_raw, new_raw)
    }
    old_path = normalized.0
    new_path = normalized.1
    ignore(diff_git_header_paths(git_paths, Some(old_path), Some(new_path)))
    has_headers = true
    i = i + 1
  } else {
    let pair = diff_git_header_paths(
      git_paths,
      meta.rename_from,
      meta.rename_to,
    )
    old_path = if meta.added { "/dev/null" } else { pair.0 }
    new_path = if meta.deleted { "/dev/null" } else { pair.1 }
  }
  guard meta.added == (old_path == "/dev/null") &&
    meta.deleted == (new_path == "/dev/null") else {
    fail("Git file mode conflicts with file headers")
  }
  match (meta.rename_from, meta.rename_to) {
    (Some(from), Some(to)) => {
      guard from == old_path && to == new_path else {
        fail("rename metadata conflicts with file headers")
      }
    }
    (None, None) => {
      guard old_path == new_path ||
        old_path == "/dev/null" ||
        new_path == "/dev/null" else {
        fail("different Git paths lack rename metadata")
      }
    }
    _ => fail("incomplete rename metadata")
  }
  if old_path.has_suffix(".mbt") || new_path.has_suffix(".mbt") {
    guard meta.old_mode != Some("120000") &&
      meta.new_mode != Some("120000") &&
      meta.old_mode != Some("160000") &&
      meta.new_mode != Some("160000") else {
      fail("MoonBit source uses a symbolic link or gitlink mode")
    }
  }
  let hunks : Array[DiffHunk] = []
  while i < lines.length() && diff_starts(lines[i], b"@@ ") {
    guard has_headers else { fail("Git text hunk lacks file headers") }
    let (hunk, next) = parse_diff_hunk(lines, i, hunks.length() + 1) catch {
      error => fail("\{new_path}: hunk \{hunks.length() + 1}: \{error}")
    }
    guard old_path != "/dev/null" || hunk.old_count == 0 else {
      fail("new file hunk has old-side lines")
    }
    guard new_path != "/dev/null" || hunk.new_count == 0 else {
      fail("deleted file hunk has new-side lines")
    }
    hunks.push(hunk)
    i = next
  }
  validate_diff_hunk_order(new_path, hunks)
  let mut binary = false
  if i < lines.length() && diff_starts(lines[i], b"Binary files ") {
    guard hunks.is_empty() &&
      diff_binary_header_matches(lines[i], old_path, new_path) else {
      fail("binary file header conflicts with section")
    }
    binary = true
    i = i + 1
  } else if i < lines.length() && lines[i] == b"GIT binary patch" {
    guard hunks.is_empty() else { fail("binary section also contains hunks") }
    binary = true
    i = diff_binary_records(lines, i + 1)
  }
  if meta.similarity == Some(100) && (!hunks.is_empty() || binary) {
    fail("100% rename similarity conflicts with content changes")
  }
  if meta.similarity is Some(score) &&
    score < 100 &&
    hunks.is_empty() &&
    !binary {
    fail("rename similarity requires represented content changes")
  }
  if binary && (old_path.has_suffix(".mbt") || new_path.has_suffix(".mbt")) {
    fail("binary MoonBit source cannot be validated")
  }
  if hunks.is_empty() && !binary {
    let changed_mode = match (meta.old_mode, meta.new_mode) {
      (Some(old_mode), Some(new_mode)) => old_mode != new_mode
      _ => false
    }
    guard !has_headers &&
      (
        changed_mode ||
        meta.added ||
        meta.deleted ||
        meta.rename_from is Some(_)
      ) else {
      fail("Git section has no recognized changes")
    }
  }
  ({ old_path, new_path, hunks, binary, }, i)
}
