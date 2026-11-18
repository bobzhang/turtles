///|
struct DiffHunk {
  old_start : Int32
  old_count : Int32
  new_start : Int32
  new_count : Int32
  lines : Array[DiffNewLine]
  old_unterminated : Bool
  new_unterminated : Bool
}

///|
/// Parse an unsigned decimal without integer overflow, returning the first
/// byte after the number. Hunk counts must fit the source offset type.
fn diff_decimal(text : Bytes, from : Int32) -> (Int32, Int32) raise {
  let mut i = from
  let mut value = 0
  while i < text.length() && text[i] >= b'0' && text[i] <= b'9' {
    let digit = text[i].to_int() - 48
    guard value <= (2147483647 - digit) / 10 else {
      fail("hunk number exceeds supported range")
    }
    value = value * 10 + digit
    i = i + 1
  }
  guard i > from else { fail("missing hunk number") }
  (value, i)
}

///|
fn diff_hunk_range(
  text : Bytes,
  from : Int32,
  sign : Byte,
) -> (Int32, Int32, Int32) raise {
  guard from < text.length() && text[from] == sign else {
    fail("invalid hunk range")
  }
  let (start, after_start) = diff_decimal(text, from + 1)
  let (count, after_count) = if after_start < text.length() &&
    text[after_start] == b',' {
    diff_decimal(text, after_start + 1)
  } else {
    (1, after_start)
  }
  guard (count == 0 || start > 0) && start <= 2147483647 - count else {
    fail("invalid or overflowing hunk range")
  }
  (start, count, after_count)
}

///|
/// The section suffix after the closing @@ is descriptive only.
fn diff_hunk_header(text : Bytes) -> (Int32, Int32, Int32, Int32) raise {
  guard text.length() >= 4 && text[:4] == b"@@ -" else {
    fail("invalid hunk header")
  }
  let (old_start, old_count, i) = diff_hunk_range(text, 3, b'-')
  guard i < text.length() && text[i] == b' ' else {
    fail("invalid hunk header")
  }
  let (new_start, new_count, j) = diff_hunk_range(text, i + 1, b'+')
  guard j + 3 <= text.length() && text[j:j + 3] == b" @@" else {
    fail("invalid hunk header")
  }
  guard j + 3 == text.length() || text[j + 3] == b' ' else {
    fail("invalid hunk header suffix")
  }
  guard old_count != 0 || new_count != 0 else { fail("empty hunk") }
  (old_start, old_count, new_start, new_count)
}

///|
/// Consume one hunk from normalized diff lines, enforcing both side counts.
/// The returned index points to the next section or hunk header. A no-newline
/// marker attaches only to the immediately preceding line and ends its side.
fn parse_diff_hunk(
  input : Array[Bytes],
  header_index : Int32,
  hunk_number : Int32,
) -> (DiffHunk, Int32) raise {
  let (old_start, old_count, new_start, new_count) = diff_hunk_header(
    input[header_index],
  )
  let lines : Array[DiffNewLine] = []
  let mut old_used = 0
  let mut new_used = 0
  let mut i = header_index + 1
  let mut previous : Byte = 0
  let mut old_ended = false
  let mut new_ended = false
  let mut changed = false
  while i < input.length() {
    let line = input[i]
    if line == b"\\ No newline at end of file" {
      guard previous != 0 else { fail("misplaced no-newline marker") }
      if previous == b'-' || previous == b' ' {
        old_ended = true
      }
      if previous == b'+' || previous == b' ' {
        new_ended = true
        let last = lines.length() - 1
        lines[last] = { ..lines[last], has_newline: false, }
      }
      previous = 0
      i = i + 1
      continue
    }
    if old_used == old_count && new_used == new_count {
      break
    }
    guard line.length() > 0 else { fail("empty diff hunk line") }
    let kind = line[0]
    if kind == b'+' || kind == b'-' {
      changed = true
    }
    if kind == b' ' || kind == b'-' {
      guard !old_ended && old_used < old_count else {
        fail("old hunk count mismatch")
      }
      old_used = old_used + 1
    }
    if kind == b' ' || kind == b'+' {
      guard !new_ended && new_used < new_count else {
        fail("new hunk count mismatch")
      }
      let number = new_start + new_used
      new_used = new_used + 1
      lines.push({
        number,
        hunk: hunk_number,
        content: line[1:].to_owned(),
        has_newline: true,
        added: kind == b'+',
      })
    }
    guard kind == b' ' || kind == b'-' || kind == b'+' else {
      fail("invalid diff hunk line")
    }
    previous = kind
    i = i + 1
  }
  guard old_used == old_count && new_used == new_count else {
    fail("truncated hunk or count mismatch")
  }
  guard changed else { fail("hunk contains no additions or deletions") }
  (
    {
      old_start,
      old_count,
      new_start,
      new_count,
      lines,
      old_unterminated: old_ended,
      new_unterminated: new_ended,
    },
    i,
  )
}

///|
/// Verify hunk ordering even for sections that have no readable new source.
fn validate_diff_hunk_order(
  path : String,
  hunks : Array[DiffHunk],
) -> Unit raise {
  let mut old_end = 0
  let mut new_end = 0
  let mut previous_old_start = -1
  let mut previous_new_start = -1
  let mut saw_unterminated_new = false
  let mut saw_unterminated_old = false
  for index, hunk in hunks {
    let old_boundary = if hunk.old_count == 0 {
      hunk.old_start
    } else {
      hunk.old_start - 1
    }
    let new_boundary = if hunk.new_count == 0 {
      hunk.new_start
    } else {
      hunk.new_start - 1
    }
    guard old_boundary >= old_end &&
      new_boundary >= new_end &&
      !(old_boundary == previous_old_start && new_boundary == previous_new_start) else {
      fail("\{path}: hunk \{index + 1}: overlapping or out-of-order ranges")
    }
    guard old_boundary - old_end == new_boundary - new_end else {
      fail("\{path}: hunk \{index + 1}: unequal omitted line counts")
    }
    guard !(saw_unterminated_old && hunk.old_count > 0) &&
      !(saw_unterminated_new && hunk.new_count > 0) else {
      fail("\{path}: hunk \{index + 1}: range follows no-newline marker")
    }
    saw_unterminated_old = saw_unterminated_old || hunk.old_unterminated
    saw_unterminated_new = saw_unterminated_new || hunk.new_unterminated
    old_end = old_boundary + hunk.old_count
    new_end = new_boundary + hunk.new_count
    previous_old_start = old_boundary
    previous_new_start = new_boundary
  }
}

///|
/// Check represented new-side bytes and deletion boundaries in a snapshot.
fn validate_diff_hunks(
  diff_file : String,
  path : String,
  source : Bytes,
  hunks : Array[DiffHunk],
) -> Array[DiffByteRange] raise {
  validate_diff_hunk_order(path, hunks)
  let source_lines = diff_source_lines(source)
  let represented : Array[DiffNewLine] = []
  for index, hunk in hunks {
    let new_boundary = if hunk.new_count == 0 {
      hunk.new_start
    } else {
      hunk.new_start - 1
    }
    guard new_boundary <= source_lines.length() &&
      hunk.new_count <= source_lines.length() - new_boundary else {
      fail(
        "\{diff_file}: \{path}: hunk \{index + 1}: new-side range \{hunk.new_start},\{hunk.new_count} exceeds \{source_lines.length()} source lines",
      )
    }
    for line in hunk.lines {
      represented.push(line)
    }
  }
  validate_diff_new_lines(diff_file, path, source, represented)
}
