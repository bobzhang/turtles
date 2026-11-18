///|
fn mk_mutation(
  path : String,
  start : Int32,
  end : Int32,
  original : String,
  replacement : String,
) -> Mutation {
  {
    path,
    start,
    end,
    line: 1,
    column: 1,
    original,
    replacement,
    group: Arithmetic,
    visibility: Private,
  }
}

///|
fn mk_prior(
  schema : Int32,
  turtles : String?,
  moon : String?,
  file_hash : String,
  outcome : Outcome,
  kills : Array[Kill]?,
) -> PriorReport {
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)] = Map([])
  mutants[mutation_identity(m)] = (m, outcome, kills, false)
  let files : Map[String, String] = Map([])
  files["a.mbt"] = file_hash
  {
    schema,
    turtles_version: turtles,
    moon_version: moon,
    target: None,
    test_scope: Some("module"),
    files,
    mutants,
  }
}

///|
test "iterate reuses only identity-matched KILLED/UNVIABLE under same toolchain" {
  let current : Map[String, String] = Map([])
  current["a.mbt"] = "hash-a"
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  match prior_reusable_outcome(prior, m, current, Some("moon x")) {
    Some((Killed, None, _)) => ()
    _ => fail("expected reused KILLED")
  }
  assert_true(
    prior_reusable_outcome(
      prior,
      m,
      current,
      Some("moon x"),
      target=Some("native"),
    )
    is None,
  )
  let native_prior = { ..prior, target: Some("native"), }
  assert_true(
    prior_reusable_outcome(
      native_prior,
      m,
      current,
      Some("moon x"),
      target=Some("native"),
    )
    is Some((Killed, None, _)),
  )
  // Survived and Timeout never reuse.
  let prior_survived = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Survived,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior_survived, m, current, Some("moon x")) is None,
    true,
  )
  let prior_timeout = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Timeout,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior_timeout, m, current, Some("moon x")) is None,
    true,
  )
  // Older schemas never reuse after the schema-4 bump.
  for old_schema in [1, 2, 3] {
    let old = mk_prior(
      old_schema,
      Some(turtles_version),
      Some("moon x"),
      "hash-a",
      Killed,
      None,
    )
    assert_eq(
      prior_reusable_outcome(old, m, current, Some("moon x")) is None,
      true,
    )
  }
  // turtles or moon version drift disables reuse.
  let other_turtles = mk_prior(
    4,
    Some("0.0.0"),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(other_turtles, m, current, Some("moon x")) is None,
    true,
  )
  let other_moon = mk_prior(
    4,
    Some(turtles_version),
    Some("moon y"),
    "hash-a",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(other_moon, m, current, Some("moon x")) is None,
    true,
  )
}

///|
test "iterate refuses reuse when file content changed" {
  let current : Map[String, String] = Map([])
  current["a.mbt"] = "new-hash"
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "old-hash",
    Killed,
    None,
  )
  assert_eq(
    prior_reusable_outcome(prior, m, current, Some("moon x")) is None,
    true,
  )
}

///|
test "iterate refuses reuse when an unmutated fingerprint file changed" {
  // The mutated file is byte-identical in both runs; a test file and
  // moon.pkg drift instead — a verdict may owe its outcome to those,
  // so no row may be reused.
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  let prior = {
    ..mk_prior(4, Some(turtles_version), Some("moon x"), "hash-a", Killed, None),
    files: {
      "a.mbt": "hash-a",
      "b_test.mbt": "hash-test",
      "moon.pkg": "hash-pkg",
    },
  }
  let changed_test : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test-drifted",
    "moon.pkg": "hash-pkg",
  }
  assert_true(
    prior_reusable_outcome(prior, m, changed_test, Some("moon x")) is None,
  )
  let changed_manifest : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg-drifted",
  }
  assert_true(
    prior_reusable_outcome(prior, m, changed_manifest, Some("moon x")) is None,
  )
  let added_file : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg",
    "new.mbt": "hash-new",
  }
  assert_true(
    prior_reusable_outcome(prior, m, added_file, Some("moon x")) is None,
  )
  // An identical fingerprint set still reuses.
  let unchanged : Map[String, String] = {
    "a.mbt": "hash-a",
    "b_test.mbt": "hash-test",
    "moon.pkg": "hash-pkg",
  }
  assert_true(
    prior_reusable_outcome(prior, m, unchanged, Some("moon x"))
    is Some((Killed, None, _)),
  )
}

///|
test "identity is content-anchored, not line-anchored" {
  // Same span+texts, different recorded line -> same identity.
  let m1 = mk_mutation("a.mbt", 10, 11, "+", "-")
  let m2 = {
    path: "a.mbt",
    start: 10,
    end: 11,
    line: 99,
    column: 99,
    original: "+",
    replacement: "-",
    group: Arithmetic,
    visibility: Private,
  }
  assert_eq(mutation_identity(m1), mutation_identity(m2))
  // Same line, shifted bytes -> different identity.
  let m3 = mk_mutation("a.mbt", 20, 21, "+", "-")
  assert_true(mutation_identity(m1) != mutation_identity(m3))
  // Same span, different replacement -> different identity.
  let m4 = mk_mutation("a.mbt", 10, 11, "+", "*")
  assert_true(mutation_identity(m1) != mutation_identity(m4))
}

///|
async test "iterate round-trips killed_by attribution from a prior report" {
  let temp = @fs.tmpdir(prefix="turtles-iterate")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    let kills_json = Json([
      {
        pkg: "probe/p",
        filename: "lib_test.mbt",
        index: 0,
        test_name: "prop idempotent",
        kind: Property,
        counterexample: Some("0"),
      },
    ]).stringify()
    let mutant_json = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"arithmetic\",\"original\":\"+\",\"replacement\":\"-\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1,\"killed_by\":\{kills_json}}"
    let report = "{\"schema\":4,\"target\":null,\"execution\":\"completed\",\"run_id\":\"test\",\"diagnostics\":null,\"inactive_mutants\":0,\"selection\":{\"version\":1,\"scope\":\"configured\",\"discovered\":1,\"diff_excluded\":0,\"target_inactive\":0,\"shard_excluded\":0,\"selected\":1,\"classified\":1,\"diff\":null,\"shard\":null},\"test_scope\":\"module\",\"turtles_version\":\"\{turtles_version}\",\"moon_version\":\"moon x\",\"files\":{\"a.mbt\":\"hash-a\"},\"mutants\":[\{mutant_json}]}"
    @fs.write_file(path_join(temp, "report.json"), report)
    guard load_prior_report(path_join(temp, "report.json")) is Some(prior) else {
      fail("expected prior report to load")
    }
    let current : Map[String, String] = Map([])
    current["a.mbt"] = "hash-a"
    let m = mk_mutation("a.mbt", 0, 1, "+", "-")
    match prior_reusable_outcome(prior, m, current, Some("moon x")) {
      Some((Killed, Some(kills), _)) => {
        assert_eq(kills.length(), 1)
        inspect(kills[0].pkg, content="probe/p")
        inspect(kills[0].filename, content="lib_test.mbt")
        inspect(kills[0].test_name, content="prop idempotent")
        debug_inspect(kills[0].kind, content="Property")
        debug_inspect(kills[0].counterexample, content="Some(\"0\")")
      }
      _ => fail("expected reused KILLED carrying its killed_by")
    }
    // A prior row without killed_by still degrades to "unavailable".
    let bare_json = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"arithmetic\",\"original\":\"+\",\"replacement\":\"-\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1}"
    let bare_report = "{\"schema\":4,\"target\":null,\"execution\":\"completed\",\"run_id\":\"test\",\"diagnostics\":null,\"inactive_mutants\":0,\"selection\":{\"version\":1,\"scope\":\"configured\",\"discovered\":1,\"diff_excluded\":0,\"target_inactive\":0,\"shard_excluded\":0,\"selected\":1,\"classified\":1,\"diff\":null,\"shard\":null},\"test_scope\":\"module\",\"turtles_version\":\"\{turtles_version}\",\"moon_version\":\"moon x\",\"files\":{\"a.mbt\":\"hash-a\"},\"mutants\":[\{bare_json}]}"
    @fs.write_file(path_join(temp, "report.json"), bare_report)
    guard load_prior_report(path_join(temp, "report.json")) is Some(bare) else {
      fail("expected prior report to load")
    }
    assert_true(
      prior_reusable_outcome(bare, m, current, Some("moon x"))
      is Some((Killed, None, _)),
    )
  })
}

///|
async test "iterate reloads boundary rows without borrowing comparison verdicts" {
  let temp = @fs.tmpdir(prefix="turtles-iterate-boundary")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(temp, recursive=true))
    // Both rows sit on the same `<` span; only the group and replacement
    // tell them apart, which is exactly what the identity tuple covers.
    let comparison_row = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"comparison\",\"original\":\"<\",\"replacement\":\">\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1}"
    let boundary_row = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"boundary\",\"original\":\"<\",\"replacement\":\"<=\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1}"
    let report = "{\"schema\":4,\"target\":null,\"execution\":\"completed\",\"run_id\":\"test\",\"diagnostics\":null,\"inactive_mutants\":0,\"selection\":{\"version\":1,\"scope\":\"configured\",\"discovered\":2,\"diff_excluded\":0,\"target_inactive\":0,\"shard_excluded\":0,\"selected\":2,\"classified\":2,\"diff\":null,\"shard\":null},\"test_scope\":\"module\",\"turtles_version\":\"\{turtles_version}\",\"moon_version\":\"moon x\",\"files\":{\"a.mbt\":\"hash-a\"},\"mutants\":[\{comparison_row},\{boundary_row}]}"
    @fs.write_file(path_join(temp, "report.json"), report)
    guard load_prior_report(path_join(temp, "report.json")) is Some(prior) else {
      fail("expected prior report to load")
    }
    let current : Map[String, String] = Map([])
    current["a.mbt"] = "hash-a"
    let comparison = {
      ..mk_mutation("a.mbt", 0, 1, "<", ">"),
      group: Comparison,
    }
    let boundary = { ..mk_mutation("a.mbt", 0, 1, "<", "<="), group: Boundary, }
    assert_true(
      prior.mutants.get(mutation_identity(comparison))
      is Some((_, Killed, _, _)),
    )
    assert_true(
      prior.mutants.get(mutation_identity(boundary)) is Some((_, Killed, _, _)),
    )
    assert_true(
      prior_reusable_outcome(prior, boundary, current, Some("moon x"))
      is Some((Killed, None, _)),
    )
    // A boundary mutation the prior run never classified stays fresh.
    let unrecorded = {
      ..mk_mutation("a.mbt", 0, 1, "<", "<="),
      start: 5,
      end: 6,
      group: Boundary,
    }
    assert_true(
      prior_reusable_outcome(prior, unrecorded, current, Some("moon x")) is None,
    )
  })
}

///|
test "mutation_id is a stable m- prefixed hex digest" {
  let id = mutation_id(mk_mutation("a.mbt", 0, 1, "+", "-"))
  assert_true(id.has_prefix("m-"))
  assert_eq(id.length(), 18)
  assert_eq(id, mutation_id(mk_mutation("a.mbt", 0, 1, "+", "-")))
}

///|
test "iterate never reuses amplification-derived kills" {
  let prior = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  let m = mk_mutation("a.mbt", 0, 1, "+", "-")
  prior.mutants[mutation_identity(m)] = (m, Killed, None, true)
  assert_true(
    prior_reusable_outcome(prior, m, prior.files, Some("moon x")) is None,
  )
  // Amplification configuration is deliberately not trusted: the same
  // conservative guard holds for a disabled or changed-factor run.
}

///|
test "iteration requires complete balanced selection metadata" {
  let valid = "{\"run_id\":\"run-1\",\"diagnostics\":null,\"inactive_mutants\":0,\"selection\":{\"version\":1,\"scope\":\"diff\",\"discovered\":2,\"diff_excluded\":1,\"target_inactive\":0,\"shard_excluded\":0,\"selected\":1,\"classified\":1,\"diff\":{\"fingerprint_algorithm\":\"fnv1a64-v1\",\"fingerprint\":\"0123456789abcdef\",\"validation\":\"represented-new-side-v1\"},\"shard\":null},\"mutants\":[{}]}"
  guard @json.parse(valid) is Object(fields) else { fail("expected object") }
  assert_true(prior_selection_complete(fields))
  for
    corrupt in [
      valid.replace(old="\"run_id\":\"run-1\"", new="\"run_id\":\"\""),
      valid.replace(old="\"classified\":1", new="\"classified\":0"),
      valid.replace(old="\"discovered\":2", new="\"discovered\":2.5"),
      valid.replace(old="\"shard\":null", new="\"shard\":{}"),
    ] {
    guard @json.parse(corrupt) is Object(object) else {
      fail("expected object")
    }
    assert_false(prior_selection_complete(object))
  }
  let prior = mk_prior(
    4,
    Some(turtles_version),
    Some("moon x"),
    "hash-a",
    Killed,
    None,
  )
  let affected = { ..prior, test_scope: Some("affected"), }
  assert_true(
    prior_reusable_outcome(
      affected,
      mk_mutation("a.mbt", 0, 1, "+", "-"),
      prior.files,
      Some("moon x"),
    )
    is None,
  )
  let unknown_moon = { ..prior, moon_version: None, }
  assert_true(
    prior_reusable_outcome(
      unknown_moon,
      mk_mutation("a.mbt", 0, 1, "+", "-"),
      prior.files,
      None,
    )
    is None,
  )
}

///|
async test "iteration ignores incomplete and old reports" {
  let root = @fs.tmpdir(prefix="turtles-iterate-incomplete")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let path = path_join(root, "report.json")
    for
      text in [
        "{\"schema\":3,\"execution\":\"completed\"}", "{\"schema\":4,\"execution\":\"running\"}",
        "{\"schema\":4,\"execution\":\"completed\"}", "{\"schema\":4.5,\"execution\":\"completed\"}",
      ] {
      @fs.write_file(path, text)
      assert_true(load_prior_report(path) is None)
    }
  })
}

///|
test "iteration rejects malformed mutation identity and amplification fields" {
  let row = "{\"path\":\"a.mbt\",\"offset\":0,\"end\":1,\"group\":\"arithmetic\",\"original\":\"+\",\"replacement\":\"-\",\"outcome\":\"KILLED\",\"line\":1,\"column\":1}"
  assert_true(parse_prior_mutant(@json.parse(row)) is Some(_))
  for
    bad in [
      row.replace(old="\"offset\":0", new="\"offset\":0.5"),
      row.replace(old="\"end\":1", new="\"end\":0"),
      row.replace(old="\"column\":1", new="\"column\":0"),
      row.replace(
        old="\"outcome\":\"KILLED\"",
        new="\"outcome\":\"KILLED\",\"amplified\":\"true\"",
      ),
    ] {
    assert_true(parse_prior_mutant(@json.parse(bad)) is None)
  }
}

///|
async test "schema four target provenance is explicit and cannot cross backend" {
  let root = @fs.tmpdir(prefix="turtles-target-provenance")
  @async.with_task_group(group => {
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let path = path_join(root, "report.json")
    let result = report_test_result(Killed)
    let files : Map[String, String] = { "m.mbt": "hash" }
    let report = build_report(
      "module",
      Some("moon test"),
      1L,
      1L,
      1L,
      "module",
      [result],
      [],
      files,
      0.0,
      target=Some("native"),
    )
    write_json_report(path, report)
    let native_text = @fs.read_file(path).text()
    guard load_prior_report(path) is Some(native_prior) else {
      fail("expected native prior")
    }
    assert_true(
      prior_reusable_outcome(
        native_prior,
        result.mutation,
        files,
        Some("moon test"),
        target=Some("native"),
      )
      is Some(_),
    )
    assert_true(
      prior_reusable_outcome(
        native_prior,
        result.mutation,
        files,
        Some("moon test"),
      )
      is None,
    )
    let json = @json.parse(native_text)
    guard json is Object(fields) else { fail("expected report object") }
    fields.remove("target")
    @fs.write_file(path, json.stringify())
    assert_true(load_prior_report(path) is None)
    let default_report = build_report(
      "module",
      Some("moon test"),
      1L,
      1L,
      1L,
      "module",
      [result],
      [],
      files,
      0.0,
    )
    write_json_report(path, default_report)
    assert_true(@fs.read_file(path).text().contains("\"target\": null"))
    guard load_prior_report(path) is Some(default_prior) else {
      fail("expected default prior")
    }
    assert_true(default_prior.target is None)
    assert_true(
      prior_reusable_outcome(
        default_prior,
        result.mutation,
        files,
        Some("moon test"),
      )
      is Some(_),
    )
  })
}
