///|
/// The differential witness (`--pbt-witness`): for each surviving mutant
/// whose enclosing top-level `fn` passes the eligibility check, append a
/// clone of the original body plus a QuickCheck comparison test to a copy
/// of the source file and run the package's tests in a throwaway
/// workspace. `witness` records the counterexample (or `"none"`);
/// `witness_skipped` records why no witness could be produced.

///|
/// Candidate helper names, most-preferred first. The mutant id goes into
/// the base so collisions need a deliberate same-name definition; retries
/// add `_1` … `_15`.
fn witness_helper_candidates(entry : FnInfo, mutid : String) -> Array[String] {
  // mutation_id looks like "m-0042abcdef...": strip the "m-" prefix into a
  // `mut`-prefixed identifier suffix.
  let hex = match mutid.strip_prefix("m-") {
    Some(hex) => hex.to_owned()
    None => mutid.replace_all(old="-", new="_")
  }
  let base = "\{entry.name}__turtles_orig__mut\{hex}"
  let candidates : Array[String] = [base]
  for k in 1..<16 {
    candidates.push("\{base}_\{k}")
  }
  candidates
}

///|
/// Candidate test names mirroring the helper candidates.
fn witness_test_names(
  entry : FnInfo,
  mutid : String,
  suffix : Int32,
) -> Array[String] {
  let base = "turtles witness \{mutid} \{entry.name}"
  let guard_name = "\{base} guard\{suffix_tag(suffix)}"
  let witness_name = "\{base}\{suffix_tag(suffix)}"
  [guard_name, witness_name]
}

///|
fn suffix_tag(suffix : Int32) -> String {
  if suffix == 0 {
    ""
  } else {
    " \{suffix}"
  }
}

///|
/// Pick the first helper/test-name pair that collides with nothing in the
/// target package's symbol/test tables. Bounded retry -> None maps to
/// `witness_skipped: "name-collision"`.
fn choose_witness_names(
  entry : FnInfo,
  mutid : String,
  pkg : PkgIndex,
) -> (String, String, String)? {
  let helpers = witness_helper_candidates(entry, mutid)
  for i in 0..<helpers.length() {
    let helper = helpers[i]
    if pkg.symbols.contains(helper) {
      continue
    }
    let names = witness_test_names(entry, mutid, i)
    let guard_name = names[0]
    let witness_name = names[1]
    if pkg.tests.contains(guard_name) || pkg.tests.contains(witness_name) {
      continue
    }
    return Some((helper, guard_name, witness_name))
  }
  None
}

///|
/// The call arguments `f` takes, spelled against generated `argN` locals:
/// `arg0` for positional/discard parameters, `name = argN` for labelled.
fn witness_call_args(entry : FnInfo) -> String {
  let args : Array[String] = []
  for i, param in entry.params {
    match param.label {
      Some(label) => args.push("\{label} = arg\{i}")
      None => args.push("arg\{i}")
    }
  }
  args.join(", ")
}

///|
/// The checkable input tuple type and the destructure prologue:
/// `(Int, Bool)` + `let (arg0, arg1) = args` for two params, the bare type
/// + `let arg0 = args` for one, `Int` + nothing for zero (the input is a
/// dummy kept only to drive the sampler).
fn witness_input(entry : FnInfo) -> (String, String) {
  let types = entry.params.map(param => param.ty_text)
  match types.length() {
    0 => ("Int", "")
    1 => ("\{types[0]}", "    let arg0 = args\n")
    _ => {
      let binders : Array[String] = []
      for i in 0..<types.length() {
        binders.push("arg\{i}")
      }
      let type_list = types.join(", ")
      let binder_list = binders.join(", ")
      ("(\{type_list})", "    let (\{binder_list}) = args\n")
    }
  }
}

///|
/// Text appended to the mutated copy of `entry.file`: the original body as
/// `helper`, the determinism guard test, and the witness test.
fn witness_appendix(
  entry : FnInfo,
  source : String,
  helper : String,
  guard_name : String,
  witness_name : String,
  quickcheck_alias~ : String = "quickcheck",
) -> String {
  let src_bytes = @utf8.encode(source)
  let clone = @utf8.decode_lossy(src_bytes[entry.impl_start:entry.name_start]) +
    helper +
    @utf8.decode_lossy(src_bytes[entry.name_end:entry.impl_end])
  // The clone reuses the original body; a `priv`/`pub` marker travels with
  // it harmlessly in the temporary workspace.
  let (input_ty, destructure) = witness_input(entry)
  let call_args = witness_call_args(entry)
  let orig_call = "\{helper}(\{call_args})"
  let mut_call = "\{entry.name}(\{call_args})"
  let buf = StringBuilder()
  buf.write_string("\n\n///|\n")
  buf.write_string(clone)
  buf.write_string("\n\n///|\ntest \"\{guard_name}\" {\n")
  buf.write_string(
    "  @\{quickcheck_alias}.check((args : \{input_ty}) => {\n\{destructure}    \{orig_call} == \{orig_call}\n  })\n}\n",
  )
  buf.write_string("\n///|\ntest \"\{witness_name}\" {\n")
  buf.write_string(
    "  @\{quickcheck_alias}.check((args : \{input_ty}) => {\n\{destructure}    \{mut_call} == \{orig_call}\n  })\n}\n",
  )
  buf.to_string()
}

///|
/// Insert `"moonbitlang/core/quickcheck"` into the package's regular
/// imports when it is not already there (scoped `for "test"`/`"wbtest"`
/// blocks do not cover a regular source file). Updates only when missing; the
/// manifest ends up with the import, returning its effective alias.
async fn ensure_quickcheck_import(
  workspace : String,
  pkg_dir : String,
) -> String? {
  let dir = if pkg_dir == "." {
    workspace
  } else {
    path_join(workspace, pkg_dir)
  }
  let text_pkg = path_join(dir, "moon.pkg")
  let json_pkg = path_join(dir, "moon.pkg.json")
  if @fs.exists(text_pkg) {
    let text = @fs.read_file(text_pkg).text() catch { _ => return None }
    let parsed = @moon_config.parse_moon_pkg(text)
    if !parsed.diagnostics.errors.is_empty() {
      return None
    }
    let effective = pkg_text_import_entries(text, "source")
    for (path, alias_) in effective {
      if path == "moonbitlang/core/quickcheck" {
        return Some(pkg_import_alias(path, alias_))
      }
    }
    for (path, alias_) in effective {
      if pkg_import_alias(path, alias_) == "quickcheck" {
        return None
      }
    }
    let mut legacy : @moon_config.Expr? = None
    for statement in parsed.ast.0 {
      let fields = match statement {
        @moon_config.Statement::Assign(field) => [field]
        @moon_config.Statement::Expr(
          @moon_config.Expr::Apply(name="options", args~, ..),
        ) => args
        _ => []
      }
      for field in fields {
        if field.key == "import" {
          if legacy is Some(_) {
            return None
          }
          legacy = Some(field.value)
        }
      }
    }
    if legacy is Some(value) {
      guard pkg_legacy_import_entries(value) is Some(_) else { return None }
      guard value is @moon_config.Expr::Array(loc~, ..) else { return None }
      // The parser reports Unicode scalar offsets; String slices use UTF-16.
      let mut start = 0
      let mut scalars = 0
      for ch in text.iter() {
        if scalars == loc.start.cnum {
          break
        }
        start += ch.to_string().length()
        scalars += 1
      }
      guard start >= 0 && start < text.length() && text[start] == '[' else {
        return None
      }
      let updated = text[:start + 1].to_owned() +
        "\n  \"moonbitlang/core/quickcheck\"," +
        text[start + 1:].to_owned()
      @fs.write_file(text_pkg, updated) catch {
        _ => return None
      }
      return Some("quickcheck")
    }
    let blocks = pkg_import_blocks(text)
    let mut has_regular = false
    for (_, scoped) in blocks {
      if scoped {
        continue
      }
      has_regular = true
    }
    let updated = if has_regular {
      // splice the new path right after the first regular block's '{'
      let tbytes = @utf8.encode(text)
      let mut done = false
      let buf = StringBuilder()
      let mut cursor = 0
      for (range, scoped) in blocks {
        if !done && !scoped {
          let (start, _) = range
          buf.write_string(@utf8.decode_lossy(tbytes[cursor:start]))
          buf.write_string("\n  \"moonbitlang/core/quickcheck\",")
          cursor = start
          done = true
        }
      }
      buf.write_string(@utf8.decode_lossy(tbytes[cursor:]))
      buf.to_string()
    } else {
      "\{text}\nimport {\n  \"moonbitlang/core/quickcheck\",\n}\n"
    }
    @fs.write_file(text_pkg, updated) catch {
      _ => return None
    }
    return Some("quickcheck")
  }
  if @fs.exists(json_pkg) {
    let text = @fs.read_file(json_pkg).text() catch { _ => return None }
    let json = @json.parse(text) catch { _ => return None }
    guard json is Object(fields) else { return None }
    let entries = match fields.get("import") {
      Some(Array(entries)) => entries
      Some(_) => return None
      None => []
    }
    let effective = pkg_last_path_entries(
      pkg_json_import_entries(text, "import"),
    )
    for (path, alias_) in effective {
      if path == "moonbitlang/core/quickcheck" {
        return Some(pkg_import_alias(path, alias_))
      }
    }
    for (path, alias_) in effective {
      if pkg_import_alias(path, alias_) == "quickcheck" {
        return None
      }
    }
    let updated = entries.copy()
    updated.push(Json("moonbitlang/core/quickcheck"))
    fields["import"] = Json::array(updated)
    @fs.write_file(json_pkg, json.stringify(indent=2)) catch {
      _ => return None
    }
    return Some("quickcheck")
  }
  None
}

///|
/// The witness phase: for every survivor whose enclosing fn is eligible,
/// write the harness, run the mutant's test packages, and fold the verdict
/// into `witness` / `witness_skipped`. One dedicated `analysis` workspace
/// is reused across survivors, swept back to the reference snapshot after
/// each — same isolation contract as the mutant workers.
async fn run_pbt_witness(
  workspace : String,
  reference : String,
  results : Array[MutationResult],
  index : ModuleIndex,
  test_timeout_ms : Int32,
  timeout_command : String?,
  target~ : String? = None,
) -> Unit {
  let manifest = Ref(snapshot_workspace(workspace))
  for i, result in results {
    if !(result.outcome is Survived) {
      continue
    }
    let mutation = result.mutation
    let mutid = mutation_id(mutation)
    let entry = match enclosing_fn(index, mutation) {
      Some(entry) => entry
      None => continue
    }
    match witness_eligible(index, entry) {
      Some(skip) => {
        results[i] = {
          ..result,
          witness_skipped: Some(witness_skip_name(skip)),
        }
        continue
      }
      None => ()
    }
    let pkg = match index.pkgs.get(entry.pkg) {
      Some(pkg) => pkg
      None => continue
    }
    let names = choose_witness_names(entry, mutid, pkg)
    guard names is Some((helper, guard_name, witness_name)) else {
      results[i] = {
        ..result,
        witness_skipped: Some(witness_skip_name(NameCollision)),
      }
      continue
    }
    results[i] = witness_one(
      workspace, entry, result, helper, guard_name, witness_name, test_timeout_ms,
      timeout_command, target,
    )
    sweep_workspace(workspace, reference, manifest.val) catch {
      _ => manifest.val = rebuild_workspace(workspace, reference)
    }
  }
}

///|
/// One survivor's witness attempt: apply the mutation, append the harness,
/// patch the manifest, run the mutant's test packages. Any filesystem or
/// compile failure maps to `harness-error` — an unsupported/undecidable
/// run is never reported as `witness: none`.
async fn witness_one(
  workspace : String,
  entry : FnInfo,
  result : MutationResult,
  helper : String,
  guard_name : String,
  witness_name : String,
  test_timeout_ms : Int32,
  timeout_command : String?,
  target : String?,
) -> MutationResult {
  let harness_error = {
    ..result,
    witness_skipped: Some(witness_skip_name(HarnessError)),
  }
  let file_abs = path_join(workspace, entry.file)
  let source = @fs.read_file(file_abs).text() catch {
    _ => return harness_error
  }
  let mutated = apply_mutation(source, result.mutation) catch {
    _ => return harness_error
  }
  guard (ensure_quickcheck_import(workspace, entry.pkg) catch { _ => None })
    is Some(quickcheck_alias) else {
    return harness_error
  }
  let appendix = witness_appendix(
    entry,
    source,
    helper,
    guard_name,
    witness_name,
    quickcheck_alias~,
  )
  @fs.write_file(file_abs, mutated + appendix) catch {
    _ => return harness_error
  }
  match
    run_moon_command(
      workspace,
      ["check"],
      test_timeout_ms,
      timeout_command,
      target~,
    ) {
    CommandSuccess => ()
    _ => return harness_error
  }
  let verdict = match
    run_moon_command(
      workspace,
      mutant_test_args(result.packages),
      test_timeout_ms,
      timeout_command,
      target~,
    ) {
    CommandSuccess => WitnessNone
    CommandFailure => witness_verdict(workspace, guard_name, witness_name)
    CommandTimeout => WitnessHarness
  }
  fold_witness(result, verdict)
}

///|
/// Witness run verdicts, internal to the phase.
enum WitnessVerdict {
  /// falsified: QuickCheck counterexample
  WitnessFound(String)
  /// ran the budget without falsifying
  WitnessNone
  WitnessNondeterministic
  /// compile/run infrastructure failure: never reported as `witness`
  WitnessHarness
}

///|
/// Read the kill records of a failed witness test run: the witness test's
/// counterexample when falsified, `nondeterministic` when only the guard
/// caught divergence, `harness-error` otherwise.
async fn witness_verdict(
  workspace : String,
  guard_name : String,
  witness_name : String,
) -> WitnessVerdict {
  let kills = match (last_test_failures(workspace) catch { _ => None }) {
    Some(kills) => kills
    None => []
  }
  witness_verdict_from_kills(kills, guard_name, witness_name)
}

///|
fn witness_verdict_from_kills(
  kills : Array[Kill],
  guard_name : String,
  witness_name : String,
) -> WitnessVerdict {
  let mut counterexample : String? = None
  for kill in kills {
    // Guard failure invalidates every differential witness regardless
    // of record order. Do not return a witness until all records agree.
    if kill.test_name == guard_name {
      return WitnessNondeterministic
    }
    if kill.test_name == witness_name {
      counterexample = Some(
        match kill.counterexample {
          Some(text) => text
          None => "(no counterexample recorded)"
        },
      )
    }
  }
  match counterexample {
    Some(text) => WitnessFound(text)
    None => WitnessHarness
  }
}

///|
/// Fold a witness verdict onto a surviving result: `witness` gets the
/// counterexample or `none`; `witness_skipped` the guard/infra reasons.
fn fold_witness(
  result : MutationResult,
  verdict : WitnessVerdict,
) -> MutationResult {
  match verdict {
    WitnessFound(counterexample) => { ..result, witness: Some(counterexample), }
    WitnessNone => { ..result, witness: Some("none"), }
    WitnessNondeterministic =>
      { ..result, witness_skipped: Some(witness_skip_name(Nondeterministic)), }
    WitnessHarness =>
      { ..result, witness_skipped: Some(witness_skip_name(HarnessError)), }
  }
}
