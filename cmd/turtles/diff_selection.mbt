///|
/// A half-open byte interval in the unmodified UTF-8 source snapshot.
struct DiffByteRange {
  start : Int32
  end : Int32
}

///|
/// One represented new-side line, after the diff parser has removed its
/// prefix and removed the patch framing terminator. A trailing CR is
/// normalized only for a line that has a source newline. The newline marker
/// is false only when the diff marks the source line as unterminated.
struct DiffNewLine {
  number : Int32
  hunk : Int32
  content : Bytes
  has_newline : Bool
  added : Bool
}

///|
/// Offsets use the original bytes, even when comparison ignores CR in CRLF.
struct DiffSourceLine {
  start : Int32
  content_end : Int32
  end : Int32
  has_newline : Bool
}

///|
fn diff_source_lines(source : Bytes) -> Array[DiffSourceLine] {
  let lines : Array[DiffSourceLine] = []
  let mut start = 0
  for i = 0; i < source.length(); i = i + 1 {
    if source[i] == b'\n' {
      let content_end = if i > start && source[i - 1] == b'\r' {
        i - 1
      } else {
        i
      }
      lines.push({ start, content_end, end: i + 1, has_newline: true, })
      start = i + 1
    }
  }
  if start < source.length() {
    lines.push({
      start,
      content_end: source.length(),
      end: source.length(),
      has_newline: false,
    })
  }
  lines
}

///|
/// Check every represented context and added line against one source snapshot.
/// The caller must first validate hunk structure and path safety. Only added
/// lines contribute to the returned byte ranges; adjacent ranges are merged.
fn validate_diff_new_lines(
  diff_file : String,
  path : String,
  source : Bytes,
  represented : Array[DiffNewLine],
) -> Array[DiffByteRange] raise {
  let lines = diff_source_lines(source)
  let ranges : Array[DiffByteRange] = []
  for expected in represented {
    guard expected.number > 0 && expected.number <= lines.length() else {
      fail(
        "\{diff_file}: \{path}: hunk \{expected.hunk}: new line \{expected.number} is outside the source",
      )
    }
    let line = lines[expected.number - 1]
    let content = source[line.start:line.content_end].to_owned()
    let expected_end = if expected.has_newline &&
      expected.content.length() > 0 &&
      expected.content[expected.content.length() - 1] == b'\r' {
      expected.content.length() - 1
    } else {
      expected.content.length()
    }
    guard content == expected.content[:expected_end].to_owned() &&
      line.has_newline == expected.has_newline else {
      fail(
        "\{diff_file}: \{path}: hunk \{expected.hunk}: new line \{expected.number} differs from source",
      )
    }
    if expected.added {
      if ranges.length() > 0 && ranges[ranges.length() - 1].end == line.start {
        let previous = ranges.pop().unwrap()
        ranges.push({ start: previous.start, end: line.end, })
      } else {
        ranges.push({ start: line.start, end: line.end, })
      }
    }
  }
  ranges
}

///|
/// Half-open spans do not intersect at a shared endpoint. Empty spans never
/// select a mutant, even when their coordinate lies inside a changed line.
fn diff_ranges_intersect(
  start : Int32,
  end : Int32,
  range : DiffByteRange,
) -> Bool {
  start < end &&
  range.start < range.end &&
  start < range.end &&
  range.start < end
}

///|
struct DiffInputs {
  ranges : Map[String, Array[DiffByteRange]]
  snapshots : Map[String, Bytes]
}

///|
struct DiffSelection {
  mutations : Array[Mutation]
  excluded : Int32
}

///|
/// Validate every represented root-module new-side source, including tests
/// and files outside candidate filters. Discovery can use these exact bytes.
async fn prepare_diff_inputs(
  root : String,
  diff_file : String,
  sections : Array[DiffSection],
) -> DiffInputs {
  let ranges : Map[String, Array[DiffByteRange]] = Map([])
  let snapshots : Map[String, Bytes] = Map([])
  let directory_entries : Map[String, Map[String, Unit]] = Map([])
  for section in sections {
    let path = section.new_path
    if section.binary {
      println("  diff excluded: \{path} (binary section)")
      continue
    }
    if path == "/dev/null" {
      println("  diff excluded: \{section.old_path} (deleted source)")
      continue
    }
    if !path.has_suffix(".mbt") {
      continue
    }
    match read_diff_source(root, path, directory_entries~) {
      None => ()
      Some(source) => {
        for byte in source {
          guard byte != 0 else {
            fail("diff source \{path}: source contains a NUL byte")
          }
        }
        ignore(
          @utf8.decode(source) catch {
            _ => fail("diff source \{path}: source is not UTF-8")
          },
        )
        let selected_ranges = validate_diff_hunks(
          diff_file,
          path,
          source,
          section.hunks,
        )
        if section.old_path == "/dev/null" && !source.is_empty() {
          guard selected_ranges.length() == 1 &&
            selected_ranges[0].start == 0 &&
            selected_ranges[0].end == source.length() else {
            fail("diff source \{path}: added file is not fully represented")
          }
        }
        ranges[path] = selected_ranges
        snapshots[path] = source
      }
    }
  }
  { ranges, snapshots, }
}

///|
/// Retain original discovery order and use each mutant's complete byte span.
fn select_diff_mutations(
  inputs : DiffInputs,
  mutations : Array[Mutation],
) -> DiffSelection {
  let selected : Array[Mutation] = []
  for mutation in mutations {
    match inputs.ranges.get(mutation.path) {
      Some(ranges) =>
        if diff_sorted_ranges_intersect(mutation.start, mutation.end, ranges) {
          selected.push(mutation)
        }
      None => ()
    }
  }
  { mutations: selected, excluded: mutations.length() - selected.length(), }
}

///|
/// Ranges from validate_diff_hunks are positive, sorted and nonoverlapping.
/// Find the first range ending after the start of this half-open span.
fn diff_sorted_ranges_intersect(
  start : Int32,
  end : Int32,
  ranges : Array[DiffByteRange],
) -> Bool {
  if start >= end {
    return false
  }
  let mut low = 0
  let mut high = ranges.length()
  while low < high {
    let middle = low + (high - low) / 2
    if ranges[middle].end <= start {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low < ranges.length() && diff_ranges_intersect(start, end, ranges[low])
}
