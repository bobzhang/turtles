///|
#cfg(not(platform="windows"))
async test "diff sources reject missing files and symlinks and verify snapshots" {
  let root = @fs.tmpdir(prefix="turtles-diff-source")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.mkdir(path_join(root, "src"))
    @fs.write_file(path_join(root, "src/a.mbt"), "hello\n")
    assert_eq(read_diff_source(root, "src/a.mbt"), Some(b"hello\n"))
    // On case-insensitive filesystems this spelling resolves to the same
    // file, but it must not silently miss the collector's exact path.
    assert_true(
      (Some(read_diff_source(root, "src/A.mbt")) catch { _ => None }) is None,
    )
    let snapshots : Map[String, Bytes] = { "src/a.mbt": b"hello\n" }
    verify_diff_snapshots(root, snapshots)
    @fs.write_file(path_join(root, "src/a.mbt"), "changed\n")
    assert_true(
      (Some(verify_diff_snapshots(root, snapshots)) catch { _ => None }) is None,
    )
    assert_true(
      (Some(read_diff_source(root, "missing.mbt")) catch { _ => None }) is None,
    )
    @fs.symlink(path_join(root, "link"), target=path_join(root, "src"))
    assert_true(
      (Some(read_diff_source(root, "link/a.mbt")) catch { _ => None }) is None,
    )
    @fs.mkdir(path_join(root, "_build"))
    @fs.symlink(
      path_join(root, "_build/linked.mbt"),
      target=path_join(root, "src/a.mbt"),
    )
    assert_true(
      (Some(read_diff_source(root, "_build/linked.mbt")) catch { _ => None })
      is None,
    )
    @fs.symlink(path_join(root, "a.mbt"), target=path_join(root, "src/a.mbt"))
    assert_true(
      (Some(read_diff_source(root, "a.mbt")) catch { _ => None }) is None,
    )
  })
}

///|
async test "diff sources exclude generated and nested module files" {
  let root = @fs.tmpdir(prefix="turtles-diff-exclusions")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.mkdir(path_join(root, "_build"))
    @fs.mkdir(path_join(root, "nested"))
    @fs.write_file(
      path_join(root, "nested/moon.mod"),
      "name = \"test/nested\"\n",
    )
    assert_true(read_diff_source(root, "_build/a.mbt") is None)
    assert_true(read_diff_source(root, "nested/a.mbt") is None)
  })
}

///|
async test "bounded diff reading accepts the limit and rejects excess" {
  let root = @fs.tmpdir(prefix="turtles-diff-limit")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let file = path_join(root, "patch")
    @fs.write_file(file, "abcd")
    assert_eq(read_diff_limited(file, 4), b"abcd")
    assert_true((Some(read_diff_limited(file, 3)) catch { _ => None }) is None)
    assert_true(
      (Some(read_diff_limited(path_join(root, "missing"), 4)) catch {
        _ => None
      })
      is None,
    )
  })
}

///|
async test "source path components must use exact filesystem spelling" {
  let root = @fs.tmpdir(prefix="turtles-diff-case")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    @fs.mkdir(path_join(root, "MixedDir"))
    @fs.write_file(path_join(root, "MixedDir/Example.mbt"), "true\n")
    assert_eq(read_diff_source(root, "MixedDir/Example.mbt"), Some(b"true\n"))
    assert_true(
      (Some(read_diff_source(root, "MixedDir/example.mbt")) catch { _ => None })
      is None,
    )
    assert_true(
      (Some(read_diff_source(root, "mixeddir/Example.mbt")) catch { _ => None })
      is None,
    )
  })
}

///|
/// These tests are deterministic witnesses for a documented limitation,
/// not an assertion that the path-based check is safe against a concurrent
/// untrusted writer. No timing-dependent scheduling or real user data is used.
#cfg(not(platform="windows"))
async test "a final-file swap between inspection and read can evade rechecking" {
  let temp = @fs.tmpdir(prefix="turtles-diff-file-race")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    @fs.mkdir(root)
    let source = path_join(root, "source.mbt")
    let saved = path_join(root, "saved.mbt")
    let outside = path_join(temp, "outside.mbt")
    @fs.write_file(source, "same content\n")
    @fs.write_file(outside, "same content\n")
    let snapshots : Map[String, Bytes] = { "source.mbt": b"same content\n" }
    let observed = read_diff_source_interposed(root, "source.mbt", () => {
      @fs.rename(source, saved)
      @fs.symlink(source, target=outside)
      assert_true(@fs.kind(source, follow_symlink=false) is SymLink)
    })
    @fs.remove(source)
    @fs.rename(saved, source)
    assert_eq(observed, Some(b"same content\n"))
    // The replacement was transient, so this check cannot reveal the read.
    verify_diff_snapshots(root, snapshots)
  })
}

///|
#cfg(not(platform="windows"))
async test "a parent-directory swap between inspection and read can evade rechecking" {
  let temp = @fs.tmpdir(prefix="turtles-diff-parent-race")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let root = path_join(temp, "module")
    let parent = path_join(root, "src")
    let saved = path_join(root, "saved")
    let outside = path_join(temp, "outside")
    @fs.mkdir(parent, recursive=true)
    @fs.mkdir(outside)
    @fs.write_file(path_join(parent, "source.mbt"), "same content\n")
    @fs.write_file(path_join(outside, "source.mbt"), "same content\n")
    let snapshots : Map[String, Bytes] = { "src/source.mbt": b"same content\n" }
    let observed = read_diff_source_interposed(root, "src/source.mbt", () => {
      @fs.rename(parent, saved)
      @fs.symlink(parent, target=outside)
      assert_true(@fs.kind(parent, follow_symlink=false) is SymLink)
    })
    @fs.remove(parent)
    @fs.rename(saved, parent)
    assert_eq(observed, Some(b"same content\n"))
    verify_diff_snapshots(root, snapshots)
  })
}
