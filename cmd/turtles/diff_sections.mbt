///|
struct DiffSection {
  old_path : String
  new_path : String
  hunks : Array[DiffHunk]
  binary : Bool
}

///|
/// Split a textual unified patch into raw lines. CRLF patch framing is
/// identified from its first line; CR belonging to source content remains
/// available for new-side comparison.
fn diff_patch_lines(
  raw : Bytes,
  line_limit~ : Int32 = 200000,
) -> Array[Bytes] raise {
  // Bound short-line object overhead before allocating any per-line copies.
  // Count a final unterminated line, but not a phantom line after trailing LF.
  let mut count = if raw.is_empty() || raw[raw.length() - 1] == b'\n' {
    0
  } else {
    1
  }
  guard count <= line_limit else {
    fail("diff exceeds \{line_limit} physical lines")
  }
  for byte in raw {
    if byte == b'\n' {
      count += 1
      guard count <= line_limit else {
        fail("diff exceeds \{line_limit} physical lines")
      }
    }
  }
  let lines : Array[Bytes] = []
  let mut start = 0
  let mut framing_known = false
  let mut crlf_framing = false
  for i = 0; i < raw.length(); i = i + 1 {
    if raw[i] == b'\n' {
      if !framing_known {
        crlf_framing = i > 0 && raw[i - 1] == b'\r'
        framing_known = true
      }
      let end = if crlf_framing && i > start && raw[i - 1] == b'\r' {
        i - 1
      } else {
        i
      }
      lines.push(raw[start:end].to_owned())
      start = i + 1
    }
  }
  if start < raw.length() {
    lines.push(raw[start:].to_owned())
  }
  lines
}

///|
/// Parse prefixless unified sections. This helper rejects unrecognized
/// content; callers handling Git section metadata must do so explicitly.
fn parse_unified_sections(raw : Bytes) -> Array[DiffSection] raise {
  let input = diff_patch_lines(raw)
  let sections : Array[DiffSection] = []
  let seen : Map[String, Bool] = Map([])
  let mut i = 0
  while i < input.length() {
    guard input[i].length() >= 4 && input[i][:4] == b"--- " else {
      fail("unrecognized unified diff section")
    }
    let old_path = diff_header_path(input[i][4:].to_owned())
    i = i + 1
    guard i < input.length() &&
      input[i].length() >= 4 &&
      input[i][:4] == b"+++ " else {
      fail("missing unified diff new-side header")
    }
    let new_path = diff_header_path(input[i][4:].to_owned())
    guard old_path != "/dev/null" || new_path != "/dev/null" else {
      fail("both diff paths are /dev/null")
    }
    if old_path != "/dev/null" {
      validate_diff_path(old_path)
    }
    if new_path != "/dev/null" {
      validate_diff_path(new_path)
    }
    // Only a full Git section can establish removable path prefixes.

    i = i + 1
    if new_path != "/dev/null" {
      guard !seen.contains(new_path) else {
        fail("duplicate diff new-side path: \{new_path}")
      }
      seen[new_path] = true
    }
    let hunks : Array[DiffHunk] = []
    while i < input.length() && input[i].length() >= 3 && input[i][:3] == b"@@ " {
      let (hunk, next) = parse_diff_hunk(input, i, hunks.length() + 1) catch {
        error => fail("\{new_path}: hunk \{hunks.length() + 1}: \{error}")
      }
      if old_path == "/dev/null" {
        guard hunk.old_start == 0 && hunk.old_count == 0 else {
          fail("new file hunk has old-side lines")
        }
      }
      if new_path == "/dev/null" {
        guard hunk.new_start == 0 && hunk.new_count == 0 else {
          fail("deleted file hunk has new-side lines")
        }
      }
      hunks.push(hunk)
      i = next
    }
    guard !hunks.is_empty() else { fail("unified diff section has no hunks") }
    validate_diff_hunk_order(new_path, hunks)
    sections.push({ old_path, new_path, hunks, binary: false, })
  }
  sections
}

///|
/// Parse Git and ordinary unified sections in order. Binary payload bytes are
/// passed to the Git parser without decoding. Reject any unrecognized text.
fn parse_diff_sections(raw : Bytes) -> Array[DiffSection] raise {
  guard raw.length() <= 64 * 1024 * 1024 else { fail("diff exceeds 64 MiB") }
  let lines = diff_patch_lines(raw)
  if raw.length() > 0 && raw[raw.length() - 1] != b'\n' && !lines.is_empty() {
    let last = lines[lines.length() - 1]
    if !last.is_empty() &&
      (last[0] == b'+' || last[0] == b'-' || last[0] == b' ') {
      fail("unterminated diff data line")
    }
  }
  let sections : Array[DiffSection] = []
  let seen : Map[String, Bool] = Map([])
  let mut i = 0
  while i < lines.length() {
    let batch : Array[DiffSection] = []
    if diff_starts(lines[i], b"diff --git ") {
      let (section, next) = parse_git_diff_section(lines, i)
      batch.push(section)
      i = next
    } else if diff_starts(lines[i], b"--- ") {
      let raw_sections = @buffer.Buffer()
      while i < lines.length() && !diff_starts(lines[i], b"diff --git ") {
        raw_sections.write_bytes(lines[i])
        raw_sections.write_byte(b'\n')
        i = i + 1
      }
      for section in parse_unified_sections(raw_sections.to_bytes()) {
        batch.push(section)
      }
    } else {
      fail("unrecognized or unsupported diff section")
    }
    for section in batch {
      if section.new_path != "/dev/null" {
        guard !seen.contains(section.new_path) else {
          fail("duplicate diff new-side path: \{section.new_path}")
        }
        seen[section.new_path] = true
      }
      sections.push(section)
    }
  }
  sections
}
