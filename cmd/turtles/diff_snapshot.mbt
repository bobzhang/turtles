///|
/// Inspect a root-module source for symlinks and collector exclusions.
/// This path-based check is not atomic with a later open; a concurrent writer
/// can replace a checked file or directory before it is read.
async fn inspect_diff_source(
  root : String,
  path : String,
  directory_entries~ : Map[String, Map[String, Unit]] = Map([]),
) -> String? {
  validate_diff_path(path)
  let parts = path.split("/").collect()
  let mut current = root
  let mut excluded : String? = None
  for i in 0..<parts.length() {
    let name = parts[i].to_owned()
    let entries = match directory_entries.get(current) {
      Some(entries) => entries
      None => {
        let names = @fs.readdir(current, include_hidden=true, sort=false) catch {
          error =>
            fail(
              "diff source \{path}: cannot inspect directory \{current}: \{error}",
            )
        }
        let entries : Map[String, Unit] = Map([])
        for name in names {
          entries[name] = ()
        }
        directory_entries[current] = entries
        entries
      }
    }
    let exact_name = entries.contains(name)
    current = path_join(current, name)
    let kind = @fs.kind(current, follow_symlink=false) catch {
      @os_error.OSError(_) as error if error.is_ENOENT() => Unknown
      error => fail("diff source \{path}: cannot inspect \{current}: \{error}")
    }
    guard exact_name || kind is Unknown else {
      fail(
        "diff source \{path}: path spelling differs from the filesystem entry",
      )
    }
    guard !(kind is SymLink) else {
      fail("diff source \{path}: symbolic links are not allowed")
    }
    if i + 1 < parts.length() {
      if excluded is None && should_skip_dir(name) {
        excluded = Some("generated directory")
      }
      if !(kind is Directory) {
        if excluded is Some(reason) && kind is Unknown {
          println("  diff excluded: \{path} (\{reason})")
          return None
        }
        fail("diff source \{path}: parent directory is missing or inaccessible")
      }
      if excluded is None && is_nested_module(current) {
        excluded = Some("nested module")
      }
    } else {
      match excluded {
        Some(reason) => {
          println("  diff excluded: \{path} (\{reason})")
          return None
        }
        None => {
          guard kind is Regular else {
            fail(
              "diff source \{path}: file is missing, inaccessible, or not regular",
            )
          }
        }
      }
    }
  }
  Some(current)
}

///|
/// The callback marks the boundary between inspection and use. Production
/// passes a no-op; tests can deterministically place a concurrent change here.
async fn read_diff_source_interposed(
  root : String,
  path : String,
  before_read : async () -> Unit,
  directory_entries~ : Map[String, Map[String, Unit]] = Map([]),
) -> Bytes? {
  match inspect_diff_source(root, path, directory_entries~) {
    Some(current) => {
      before_read()
      Some(@fs.read_file(current).binary()) catch {
        error => fail("diff source \{path}: cannot read source: \{error}")
      }
    }
    None => None
  }
}

///|
async fn read_diff_source(
  root : String,
  path : String,
  directory_entries~ : Map[String, Map[String, Unit]] = Map([]),
) -> Bytes? {
  read_diff_source_interposed(root, path, () => (), directory_entries~)
}

///|
/// Recheck all validated sources both in the live tree and in the reference
/// copy. A byte comparison, rather than a hash, binds discovery to execution.
async fn verify_diff_snapshots(
  root : String,
  snapshots : Map[String, Bytes],
) -> Unit {
  // One cache per pass, never reused across source/reference revalidation.
  let directory_entries : Map[String, Map[String, Unit]] = Map([])
  for path, expected in snapshots {
    guard read_diff_source(root, path, directory_entries~) is Some(observed) &&
      observed == expected else {
      fail("diff source \{path}: source changed after validation")
    }
  }
}

///|
/// Read at most the configured bound even if the file grows while reading.
/// A preliminary stat alone would not protect the allocation or the limit.
async fn read_diff_limited(path : String, limit : Int32) -> Bytes {
  let file = @fs.open(path, mode=ReadOnly) catch {
    error => fail("cannot read diff \{path}: \{error}")
  }
  defer file.close()
  let output = @buffer.Buffer()
  while true {
    let part = file.read_some(max_len=65536) catch {
      error => fail("cannot read diff \{path}: \{error}")
    }
    match part {
      None => break
      Some(bytes) => {
        guard !bytes.is_empty() else {
          fail("cannot read diff \{path}: empty read")
        }
        guard bytes.length() <= limit - output.length() else {
          fail("diff \{path} exceeds size limit")
        }
        output.write_bytesview(bytes)
      }
    }
  }
  output.to_bytes()
}
