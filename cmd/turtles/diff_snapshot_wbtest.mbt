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
