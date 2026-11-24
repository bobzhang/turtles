///|
fn schemata_for(source : String) -> Schemata raise {
  let config = {
    ..default_project_config(),
    operators: Some([
      Comparison,
      Boolean,
      Arithmetic,
      Literal,
      Condition,
      Body,
      Boundary,
    ]),
  }
  let mutations = scan_source("lib/a.mbt", source, config)
  let entries : Array[(Int32, Mutation)] = []
  for i, mutation in mutations {
    entries.push((i + 1, mutation))
  }
  build_schemata({ "lib/a.mbt": source }, entries)
}

///|
test "schemata renders nested sites once each" {
  let source =
    #|///|
    #|fn f(a : Int, b : Int, ok : Bool) -> Int {
    #|  if a < b && ok {
    #|    a + b * 2
    #|  } else {
    #|    -a
    #|  }
    #|}
  let schemata = schemata_for(source)
  inspect(
    schemata.files[0].generated,
    content=(
      #|///|
      #|fn f(a : Int, b : Int, ok : Bool) -> Int {
      #|  match turtles_active() { 1 => { 0 }; 2 => { 1 }; 3 => { -1 }; _ => { (); if (match turtles_active() { 4 => true; 5 => false; _ => (({ let turtles_l = (turtles_op_lt_gt_le(a, b, 7, 8)); if turtles_l == (turtles_active() == 6) { turtles_l } else { (ok) } })) }) {
      #|    turtles_op_add_sub(a, turtles_op_mul_div(b, 2, 10), 9)
      #|  } else {
      #|    turtles_op_neg(a, 11)
      #|  } } }
      #|}
    ),
  )
  inspect(schemata.instrumented_ids().length(), content="11")
}

///|
test "schemata leaves pattern-binding conditions on the classic path" {
  let source =
    #|///|
    #|fn g(x : Int?) -> Bool {
    #|  if x is Some(v) && v > 0 {
    #|    true
    #|  } else {
    #|    false
    #|  }
    #|}
  let schemata = schemata_for(source)
  inspect(
    schemata.files[0].generated,
    content=(
      #|///|
      #|fn g(x : Int?) -> Bool {
      #|  match turtles_active() { 1 => { true }; 2 => { false }; _ => { (); if x is Some(v) && turtles_op_gt_lt_ge(v, 0, 6, 7) {
      #|    (turtles_active() != 8)
      #|  } else {
      #|    (turtles_active() == 9)
      #|  } } }
      #|}
    ),
  )
}

///|
test "schemata rejects the innermost site at a diagnostic" {
  let source =
    #|///|
    #|fn h(a : String, b : String) -> String {
    #|  a + b
    #|}
  let schemata = schemata_for(source)
  let file = schemata.files[0]
  // point the diagnostic at the `+` helper call, inside the body site
  let line3 = file.generated.split("\n").map(l => l.to_owned()).to_array()[2]
  let column = line3.find("turtles_op_add_sub").unwrap() + 1
  let errors = [
    { path: "/tmp/x/lib/a.mbt", line: 3, column, message: "no Sub", },
  ]
  inspect(
    schemata.reject_errors(errors, path => path.replace(old="/tmp/x/", new="")),
    content="true",
  )
  schemata.render()
  // the body site survives; only the `+` site fell back to classic
  inspect(file.generated.contains("turtles_op_add_sub"), content="false")
  inspect(file.generated.contains("xyzzy"), content="true")
}

///|
test "schemata parses moon check json errors" {
  let output =
    #|{"$message_type":"diagnostic","level":"warning","path":"/a/b.mbt","loc":"3:11-3:14","message":"w"}
    #|{"$message_type":"diagnostic","level":"error","error_code":4021,"path":"/a/b.mbt","loc":"7:2-7:9","message":"boom"}
  let errors = parse_check_errors(output)
  inspect(errors.length(), content="1")
  inspect(
    "\{errors[0].line}:\{errors[0].column} \{errors[0].message}",
    content="7:2 boom",
  )
}

///|
test "schemata helper source" {
  inspect(
    infix_helper_source("<", [">", "<="]),
    content=(
      #|///|
      #|fn[T : Compare] turtles_op_lt_gt_le(a : T, b : T, i0 : Int, i1 : Int) -> Bool {
      #|  let m = turtles_active()
      #|  if m == i0 {
      #|    a > b
      #|  } else if m == i1 {
      #|    a <= b
      #|  } else {
      #|    a < b
      #|  }
      #|}
      #|
    ),
  )
}
