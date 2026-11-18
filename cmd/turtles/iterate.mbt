///|
/// A prior run's report, distilled for --iterate reuse decisions.
struct PriorReport {
  schema : Int32
  turtles_version : String?
  moon_version : String?
  target : String?
  test_scope : String?
  files : Map[String, String]
  /// identity -> (mutation, outcome, kills, amplified): the flag travels
  /// so a reused KILLED verdict can keep --pbt-amplify's attribution
  mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)]
}

///|
fn json_string(value : Json) -> String? {
  match value {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn json_field_string(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(value) => json_string(value)
    None => None
  }
}

///|
fn outcome_from_name(name : String) -> Outcome? {
  match name {
    "KILLED" => Some(Killed)
    "SURVIVED" => Some(Survived)
    "TIMEOUT" => Some(Timeout)
    "UNVIABLE" => Some(Unviable)
    _ => None
  }
}

///|
/// Read a completed schema-4 report for --iterate. Older or partial reports yield
/// None rather than failing the run — reuse is an optimization, never
/// required for correctness.
async fn load_prior_report(path : String) -> PriorReport? {
  let text = @fs.read_file(path).text() catch { _ => return None }
  let json = @json.parse(text) catch { _ => return None }
  guard json is Object(top) else { return None }
  let schema = match json_field_string_or_number(top, "schema") {
    Some(n) => n
    None => return None
  }
  guard schema == 4 &&
    json_field_string(top, "execution") == Some("completed") &&
    prior_selection_complete(top) else {
    return None
  }
  match top.get("target") {
    Some(Null) | Some(String(_)) => ()
    _ => return None
  }
  let files : Map[String, String] = Map([])
  match top.get("files") {
    Some(Object(entries)) =>
      for entry in entries {
        match json_string(entry.1) {
          Some(hash) => files[entry.0] = hash
          None => ()
        }
      }
    _ => ()
  }
  let mutants : Map[String, (Mutation, Outcome, Array[Kill]?, Bool)] = Map([])
  match top.get("mutants") {
    Some(Array(entries)) =>
      for entry in entries {
        match parse_prior_mutant(entry) {
          Some((mutation, outcome, kills, amplified)) =>
            mutants[mutation_identity(mutation)] = (
              mutation, outcome, kills, amplified,
            )
          None => ()
        }
      }
    _ => ()
  }
  Some({
    schema,
    turtles_version: json_field_string(top, "turtles_version"),
    moon_version: json_field_string(top, "moon_version"),
    target: json_field_string(top, "target"),
    test_scope: json_field_string(top, "test_scope"),
    files,
    mutants,
  })
}

///|
fn json_field_string_or_number(
  fields : Map[String, Json],
  name : String,
) -> Int32? {
  match fields.get(name) {
    Some(Number(n, ..)) if n >= 0.0 &&
      n <= 2147483647.0 &&
      n.to_int().to_double() == n => Some(n.to_int())
    _ => None
  }
}

///|
/// A completed report must describe a coherent final selection. Treat
/// malformed or partial metadata as a cache miss rather than guessing.
fn prior_selection_complete(top : Map[String, Json]) -> Bool {
  guard json_field_string(top, "run_id") is Some(run_id) && run_id != "" else {
    return false
  }
  guard top.get("diagnostics") is Some(_) else { return false }
  guard top.get("selection") is Some(Object(selection)) &&
    top.get("mutants") is Some(Array(mutants)) else {
    return false
  }
  guard json_field_string_or_number(selection, "version") == Some(1) else {
    return false
  }
  guard json_field_string_or_number(selection, "discovered") is Some(discovered) &&
    json_field_string_or_number(selection, "diff_excluded")
    is Some(diff_excluded) &&
    json_field_string_or_number(selection, "target_inactive") is Some(inactive) &&
    json_field_string_or_number(selection, "shard_excluded")
    is Some(shard_excluded) &&
    json_field_string_or_number(selection, "selected") is Some(selected) &&
    json_field_string_or_number(selection, "classified") is Some(classified) &&
    json_field_string_or_number(top, "inactive_mutants") == Some(inactive) else {
    return false
  }
  guard classified == selected &&
    selected == mutants.length() &&
    discovered.to_int64() ==
    diff_excluded.to_int64() +
    inactive.to_int64() +
    shard_excluded.to_int64() +
    selected.to_int64() else {
    return false
  }
  guard selection.get("shard") is Some(Null) && shard_excluded == 0 else {
    return false
  }
  match json_field_string(selection, "scope") {
    Some("configured") =>
      selection.get("diff") is Some(Null) && diff_excluded == 0
    Some("diff") => {
      guard selection.get("diff") is Some(Object(diff)) else { return false }
      json_field_string(diff, "fingerprint_algorithm") == Some("fnv1a64-v1") &&
      json_field_string(diff, "validation") == Some("represented-new-side-v1") &&
      json_field_string(diff, "fingerprint") is Some(fingerprint) &&
      fingerprint.length() == 16
    }
    _ => false
  }
}

///|
fn parse_prior_mutant(json : Json) -> (Mutation, Outcome, Array[Kill]?, Bool)? {
  guard json is Object(fields) else { return None }
  guard fields.get("path") is Some(String(path)) else { return None }
  guard json_field_string_or_number(fields, "offset") is Some(start) &&
    json_field_string_or_number(fields, "end") is Some(end) &&
    start < end else {
    return None
  }
  guard fields.get("group") is Some(String(group_text)) else { return None }
  guard fields.get("original") is Some(String(original)) else { return None }
  guard fields.get("replacement") is Some(String(replacement)) else {
    return None
  }
  guard fields.get("outcome") is Some(String(outcome_text)) else { return None }
  guard json_field_string_or_number(fields, "line") is Some(line) &&
    line > 0 &&
    json_field_string_or_number(fields, "column") is Some(column) &&
    column > 0 else {
    return None
  }
  let group = operator_group_from_string(group_text) catch { _ => return None }
  guard outcome_from_name(outcome_text) is Some(outcome) else { return None }
  let amplified = match fields.get("amplified") {
    Some(True) => true
    Some(False) | None => false
    _ => return None
  }
  Some(
    (
      {
        path,
        start,
        end,
        line,
        column,
        group,
        original,
        replacement,
        // The parsed mutant only ever serves as an identity key; the
        // reused result reuses the current scan's mutation, whose
        // visibility is authoritative.
        visibility: Private,
      },
      outcome,
      kills_from_json(json),
      amplified,
    ),
  )
}

///|
/// True only when both fingerprint maps agree on the same file set and
/// hashes — a file added, removed, or edited in either direction makes
/// prior verdicts unverifiable.
fn fingerprints_match(
  prior : Map[String, String],
  current : Map[String, String],
) -> Bool {
  guard prior.length() == current.length() else { return false }
  for path, hash in prior {
    if current.get(path) != Some(hash) {
      return false
    }
  }
  true
}

///|
/// Reuse is only ever an optimization: any doubt sends the mutant back
/// through the classifier. Reuse a prior KILLED/UNVIABLE verdict iff the
/// mutant's identity tuple matches (path + byte span + both texts +
/// operator group — never line numbers), the whole fingerprint map is
/// unchanged — a verdict may owe its outcome to a test file, `moon.pkg`
/// target rules, `moon.mod`, or `turtles.toml`, not just the mutated
/// source — and the same turtles/moon toolchain produced the prior
/// report. Survived/Timeout are never reused — they are exactly what an
/// iterated run must re-examine.
fn prior_reusable_outcome(
  prior : PriorReport,
  mutation : Mutation,
  current_files : Map[String, String],
  moon_version : String?,
  target~ : String? = None,
) -> (Outcome, Array[Kill]?, Bool)? {
  if prior.schema != 4 {
    return None
  }
  if prior.turtles_version != Some(turtles_version) {
    return None
  }
  if moon_version is None || prior.moon_version != moon_version {
    return None
  }
  if prior.target != target || prior.test_scope != Some("module") {
    return None
  }
  guard fingerprints_match(prior.files, current_files) else { return None }
  guard prior.files.get(mutation.path) is Some(recorded_hash) &&
    current_files.get(mutation.path) == Some(recorded_hash) else {
    return None
  }
  guard prior.mutants.get(mutation_identity(mutation))
    is Some((_, outcome, kills, amplified)) else {
    return None
  }
  // Amplification changes both budget and seeds. Its kills are never
  // reusable, even when amplification is enabled again: conservatively
  // reclassify and rerun the current analysis instead of losing provenance.
  if amplified {
    return None
  }
  match outcome {
    // The kill's attribution travels with the verdict: a reused row
    // keeps the prior report's killed_by rather than degrading to
    // "unavailable". `amplified` is carried along and only emitted when
    // the current run also has --pbt-amplify on.
    Killed => Some((outcome, kills, amplified))
    Unviable => Some((outcome, None, false))
    Survived | Timeout => None
  }
}
