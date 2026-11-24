// Mutant schemata: compile every mutant into one program and pick the
// active one at runtime through the TURTLES_MUTANT environment variable.
//
// The classic path writes one mutant, runs `moon check` and `moon test`,
// and restores the file: one rebuild per mutant. Schemata mode rewrites
// each mutation site so all its variants are present at once, e.g.
//
//   a < b      ~>  turtles_op_lt_gt_le(a, b, 17, 18)
//   x && y     ~>  ({ let turtles_l = (x); if turtles_l == (turtles_active() == 3) { turtles_l } else { (y) } })
//   if c {..}  ~>  if (match turtles_active() { 5 => true, 6 => false, _ => (c) }) {..}
//
// Operands appear exactly once, so nested sites never blow up the source
// and evaluation order (including `&&`/`||` short-circuiting) is kept.
// The instrumented tree is type-checked once; sites the checker rejects
// (a `+ -> -` on `String`, a literal in a `const`, ...) are dropped and
// their mutants fall back to the classic per-mutant path, so verdicts
// match the classic run. Every remaining mutant then costs only a
// `moon test` against an already-built tree.

///|
let schemata_env_var : String = "TURTLES_MUTANT"

///|
let schemata_helper_file : String = "turtles_schemata_generated.mbt"

///|
priv enum SiteKind {
  /// binary operator rewritten to a generic helper call
  SiteInfix(String)
  /// `&&` / `||`, rewritten inline to keep short-circuiting
  SiteBool(String)
  /// unary minus
  SiteUnary
  SiteLiteral(Bool)
  SiteCondition
  SiteBody
}

///|
priv struct SchemaVariant {
  id : Int32
  replacement : String
}

///|
priv struct SchemaSite {
  kind : SiteKind
  /// outer byte range in the original source
  start : Int32
  end : Int32
  /// byte ranges re-rendered (recursively) inside the template
  holes : Array[(Int32, Int32)]
  variants : Array[SchemaVariant]
  /// outer site wins on equal ranges (body > condition > operator > literal)
  rank : Int32
  mut rendered : Bool
  /// scalar range in the generated text, for diagnostic attribution
  mut gen_start : Int32
  mut gen_end : Int32
}

///|
fn site_key(start : Int32, end : Int32, tag : String) -> String {
  "\{start}:\{end}:\{tag}"
}

///|
fn mutation_site_tag(group : OperatorGroup) -> String {
  match group {
    Literal => "lit"
    Condition => "cond"
    Body => "body"
    Comparison | Boolean | Arithmetic | Boundary => "op"
  }
}

///|
priv struct IsFinder {
  mut found : Bool
}

///|
impl @syntax.IterVisitor for IsFinder with fn visit_Expr_Is(
  self,
  expr~,
  pat~,
  loc~,
) {
  self.found = true
  @syntax.IterVisitor::visit_Expr_Is(
    @syntax.IterVisitor::base(self),
    expr~,
    pat~,
    loc~,
  )
}

///|
/// `x is Some(v) && f(v)` and `if x is Some(v) { v }` bind names that
/// flow out of the expression; wrapping it in a block or a match arm
/// would cut that scope. Such sites stay on the classic path.
fn expr_contains_is(expr : @syntax.Expr) -> Bool {
  let finder = IsFinder::{ found: false, }
  @syntax.IterVisitor::visit_Expr(finder, expr)
  finder.found
}

///|
priv struct SchemaVisitor {
  boundaries : Array[Int32]
  index : Map[String, Array[SchemaVariant]]
  sites : Array[SchemaSite]
}

///|
fn SchemaVisitor::byte(self : SchemaVisitor, scalar : Int32) -> Int32 {
  source_byte_offset(self.boundaries, scalar)
}

///|
fn SchemaVisitor::lookup(
  self : SchemaVisitor,
  start_scalar : Int32,
  end_scalar : Int32,
  tag : String,
) -> Array[SchemaVariant]? {
  self.index.get(site_key(self.byte(start_scalar), self.byte(end_scalar), tag))
}

///|
fn SchemaVisitor::add(
  self : SchemaVisitor,
  kind : SiteKind,
  loc : (Int32, Int32),
  holes : Array[(Int32, Int32)],
  variants : Array[SchemaVariant],
  rank : Int32,
) -> Unit {
  self.sites.push({
    kind,
    start: self.byte(loc.0),
    end: self.byte(loc.1),
    holes: holes.map(hole => (self.byte(hole.0), self.byte(hole.1))),
    variants,
    rank,
    rendered: false,
    gen_start: 0,
    gen_end: 0,
  })
}

///|
fn span(loc : @basic.Location) -> (Int32, Int32) {
  (loc.start.cnum, loc.end.cnum)
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Expr_Infix(
  self,
  op~,
  lhs~,
  rhs~,
  loc~,
) {
  match op.name {
    @syntax.LongIdent::Ident(name~) =>
      match self.lookup(op.loc.start.cnum, op.loc.end.cnum, "op") {
        Some(variants) =>
          if name == "&&" || name == "||" {
            if !expr_contains_is(lhs) && !expr_contains_is(rhs) {
              self.add(
                SiteBool(name),
                span(loc),
                [span(lhs.loc()), span(rhs.loc())],
                variants,
                2,
              )
            }
          } else {
            self.add(
              SiteInfix(name),
              span(loc),
              [span(lhs.loc()), span(rhs.loc())],
              variants,
              2,
            )
          }
        None => ()
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Infix(
    @syntax.IterVisitor::base(self),
    op~,
    lhs~,
    rhs~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Expr_Unary(
  self,
  op~,
  expr~,
  loc~,
) {
  match op.name {
    @syntax.LongIdent::Ident(name~) if name == "-" =>
      match
        self.lookup(
          op.loc.start.cnum,
          op.loc.start.cnum + name.char_length(),
          "op",
        ) {
        Some(variants) =>
          self.add(SiteUnary, span(loc), [span(expr.loc())], variants, 2)
        None => ()
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Unary(
    @syntax.IterVisitor::base(self),
    op~,
    expr~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Expr_Constant(
  self,
  c~,
  loc~,
) {
  match c {
    @syntax.Constant::Bool(value) =>
      match self.lookup(loc.start.cnum, loc.end.cnum, "lit") {
        Some(variants) =>
          self.add(SiteLiteral(value), span(loc), [], variants, 1)
        None => ()
      }
    _ => ()
  }
  @syntax.IterVisitor::visit_Expr_Constant(
    @syntax.IterVisitor::base(self),
    c~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Expr_If(
  self,
  cond~,
  ifso~,
  ifnot~,
  loc~,
) {
  let cond_loc = cond.loc()
  match self.lookup(cond_loc.start.cnum, cond_loc.end.cnum, "cond") {
    Some(variants) =>
      if !expr_contains_is(cond) {
        self.add(SiteCondition, span(cond_loc), [span(cond_loc)], variants, 3)
      }
    None => ()
  }
  @syntax.IterVisitor::visit_Expr_If(
    @syntax.IterVisitor::base(self),
    cond~,
    ifso~,
    ifnot~,
    loc~,
  )
}

///|
fn SchemaVisitor::body(
  self : SchemaVisitor,
  decl_body : @syntax.DeclBody,
) -> Unit {
  guard decl_body is @syntax.DeclBody::DeclBody(expr~) else { return }
  let loc = expr.loc()
  match self.lookup(loc.start.cnum, loc.end.cnum, "body") {
    Some(variants) => self.add(SiteBody, span(loc), [span(loc)], variants, 4)
    None => ()
  }
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Impl_TopFuncDef(
  self,
  fun_decl~,
  decl_body~,
  where_clause~,
  loc~,
) {
  self.body(decl_body)
  @syntax.IterVisitor::visit_Impl_TopFuncDef(
    @syntax.IterVisitor::base(self),
    fun_decl~,
    decl_body~,
    where_clause~,
    loc~,
  )
}

///|
impl @syntax.IterVisitor for SchemaVisitor with fn visit_Impl_TopImpl(
  self,
  self_ty~,
  trait_~,
  method_name~,
  quantifiers~,
  method_quantifiers~,
  params~,
  ret_ty~,
  err_ty~,
  nocancel_~,
  body~,
  vis~,
  loc~,
  attrs~,
  doc~,
) {
  self.body(body)
  @syntax.IterVisitor::visit_Impl_TopImpl(
    @syntax.IterVisitor::base(self),
    self_ty~,
    trait_~,
    method_name~,
    quantifiers~,
    method_quantifiers~,
    params~,
    ret_ty~,
    err_ty~,
    nocancel_~,
    body~,
    vis~,
    loc~,
    attrs~,
    doc~,
  )
}

///|
/// One source file prepared for schemata: its sites, and which mutation
/// ids each site carries. `enabled` flips off when the checker or the
/// instrumented baseline rejects a site.
priv struct SchemaFile {
  path : String
  source : String
  bytes : Bytes
  sites : Array[SchemaSite]
  enabled : Array[Bool]
  mut generated : String
}

///|
fn build_schema_file(
  path : String,
  source : String,
  entries : Array[(Int32, Mutation)],
) -> SchemaFile raise {
  let bytes = @utf8.encode(source)
  let index : Map[String, Array[SchemaVariant]] = Map([])
  for entry in entries {
    let (id, mutation) = entry
    let key = site_key(
      mutation.start,
      mutation.end,
      mutation_site_tag(mutation.group),
    )
    let variant = { id, replacement: mutation.replacement, }
    match index.get(key) {
      Some(list) => list.push(variant)
      None => index[key] = [variant]
    }
  }
  let (impls, reports) = @parser.parse_string(source, name=path)
  if reports.length() != 0 {
    fail("parser failed for \{path}")
  }
  let visitor = SchemaVisitor::{
    boundaries: source_byte_boundaries(bytes),
    index,
    sites: [],
  }
  impls.each(impl_ => @syntax.IterVisitor::visit_Impl(visitor, impl_))
  let sites = visitor.sites
  sites.sort_by((a, b) => {
    if a.start != b.start {
      a.start.compare(b.start)
    } else if a.end != b.end {
      b.end.compare(a.end)
    } else {
      b.rank.compare(a.rank)
    }
  })
  let enabled = Array::make(sites.length(), true)
  { path, source, bytes, sites, enabled, generated: source, }
}

///|
fn op_helper_suffix(op : String) -> String? {
  match op {
    "==" => Some("eq")
    "!=" => Some("ne")
    "<" => Some("lt")
    "<=" => Some("le")
    ">" => Some("gt")
    ">=" => Some("ge")
    "+" => Some("add")
    "-" => Some("sub")
    "*" => Some("mul")
    "/" => Some("div")
    _ => None
  }
}

///|
fn op_trait(op : String) -> String {
  match op {
    "==" | "!=" => "Eq"
    "<" | "<=" | ">" | ">=" => "Compare"
    "+" => "Add"
    "-" => "Sub"
    "*" => "Mul"
    _ => "Div"
  }
}

///|
fn op_is_comparison(op : String) -> Bool {
  match op {
    "==" | "!=" | "<" | "<=" | ">" | ">=" => true
    _ => false
  }
}

///|
/// Generic helper for one operator and its ordered replacement list:
/// `fn[T : Compare] turtles_op_lt_gt_le(a : T, b : T, i0 : Int, i1 : Int) -> Bool`.
fn infix_helper_name(op : String, replacements : Array[String]) -> String? {
  guard op_helper_suffix(op) is Some(base) else { return None }
  let parts = ["turtles_op", base]
  for replacement in replacements {
    guard op_helper_suffix(replacement) is Some(name) else { return None }
    parts.push(name)
  }
  Some(parts.join("_"))
}

///|
fn infix_helper_source(op : String, replacements : Array[String]) -> String {
  let name = infix_helper_name(op, replacements).unwrap()
  let traits : Array[String] = [op_trait(op)]
  for replacement in replacements {
    let t = op_trait(replacement)
    if !traits.contains(t) {
      traits.push(t)
    }
  }
  let ret = if op_is_comparison(op) { "Bool" } else { "T" }
  let params = ["a : T", "b : T"]
  for i in 0..<replacements.length() {
    params.push("i\{i} : Int")
  }
  let body = StringBuilder()
  body.write_string("  let m = turtles_active()\n  ")
  for i, replacement in replacements {
    body.write_string("if m == i\{i} {\n    a \{replacement} b\n  } else ")
  }
  body.write_string("{\n    a \{op} b\n  }\n")
  "///|\nfn[T : \{traits.join(" + ")}] \{name}(\{params.join(", ")}) -> \{ret} {\n\{body.to_string()}}\n"
}

///|
let schemata_neg_helper : String =
  #|///|
  #|fn[T : Neg] turtles_op_neg(a : T, i0 : Int) -> T {
  #|  if turtles_active() == i0 {
  #|    a
  #|  } else {
  #|    -a
  #|  }
  #|}

///|
/// The runtime selector, one copy per instrumented package. It reads
/// TURTLES_MUTANT once through each backend's raw FFI and never calls
/// library code: the package under test may itself be `builtin`, whose
/// own (mutated) functions must not decide which mutant is active.
let schemata_runtime : String =
  #|// Generated by turtles --schemata. Do not edit.
  #|
  #|///|
  #|priv struct TurtlesCell {
  #|  mut v : Int
  #|}
  #|
  #|///|
  #|let turtles_cell : TurtlesCell = { v: -1 }
  #|
  #|///|
  #|fn turtles_active() -> Int {
  #|  if turtles_cell.v < 0 {
  #|    turtles_cell.v = turtles_env()
  #|  }
  #|  turtles_cell.v
  #|}
  #|
  #|///|
  #|#cfg(target="js")
  #|extern "js" fn turtles_env() -> Int =
  #|  #| () => { const e = (typeof process !== "undefined" && process.env) ? process.env.TURTLES_MUTANT : undefined; return e ? (parseInt(e, 10) | 0) : 0; }
  #|
  #|///|
  #|#cfg(any(target="native", target="llvm"))
  #|#external
  #|priv type TurtlesCStr
  #|
  #|///|
  #|#cfg(any(target="native", target="llvm"))
  #|#borrow(name)
  #|extern "c" fn turtles_getenv(name : Bytes) -> TurtlesCStr = "getenv"
  #|
  #|///|
  #|#cfg(any(target="native", target="llvm"))
  #|#borrow(name, value)
  #|extern "c" fn turtles_setenv(name : Bytes, value : Bytes, overwrite : Int) -> Int = "setenv"
  #|
  #|///|
  #|#cfg(any(target="native", target="llvm"))
  #|extern "c" fn turtles_atoi(s : TurtlesCStr) -> Int = "atoi"
  #|
  #|///|
  #|#cfg(any(target="native", target="llvm"))
  #|fn turtles_env() -> Int {
  #|  // overwrite=0 only fills in a missing variable, so getenv never
  #|  // returns NULL below.
  #|  ignore(turtles_setenv(b"TURTLES_MUTANT\x00", b"0\x00", 0))
  #|  turtles_atoi(turtles_getenv(b"TURTLES_MUTANT\x00"))
  #|}
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|#external
  #|priv type TurtlesXStr
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|#external
  #|priv type TurtlesXCreate
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|#external
  #|priv type TurtlesXRead
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_begin_create() -> TurtlesXCreate = "__moonbit_fs_unstable" "begin_create_string"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_append(h : TurtlesXCreate, ch : Char) = "__moonbit_fs_unstable" "string_append_char"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_finish_create(h : TurtlesXCreate) -> TurtlesXStr = "__moonbit_fs_unstable" "finish_create_string"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_exists(key : TurtlesXStr) -> Bool = "__moonbit_fs_unstable" "get_env_var_exists"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_get(key : TurtlesXStr) -> TurtlesXStr = "__moonbit_fs_unstable" "get_env_var"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_begin_read(s : TurtlesXStr) -> TurtlesXRead = "__moonbit_fs_unstable" "begin_read_string"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_read_char(h : TurtlesXRead) -> Int = "__moonbit_fs_unstable" "string_read_char"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_finish_read(h : TurtlesXRead) = "__moonbit_fs_unstable" "finish_read_string"
  #|
  #|///|
  #|#cfg(any(target="wasm", target="wasm-gc"))
  #|fn turtles_env() -> Int {
  #|  let h = turtles_begin_create()
  #|  turtles_append(h, 'T')
  #|  turtles_append(h, 'U')
  #|  turtles_append(h, 'R')
  #|  turtles_append(h, 'T')
  #|  turtles_append(h, 'L')
  #|  turtles_append(h, 'E')
  #|  turtles_append(h, 'S')
  #|  turtles_append(h, '_')
  #|  turtles_append(h, 'M')
  #|  turtles_append(h, 'U')
  #|  turtles_append(h, 'T')
  #|  turtles_append(h, 'A')
  #|  turtles_append(h, 'N')
  #|  turtles_append(h, 'T')
  #|  let key = turtles_finish_create(h)
  #|  if !turtles_exists(key) {
  #|    return 0
  #|  }
  #|  let r = turtles_begin_read(turtles_get(key))
  #|  let mut n = 0
  #|  while true {
  #|    let ch = turtles_read_char(r)
  #|    if ch < 48 || ch > 57 {
  #|      break
  #|    }
  #|    n = n * 10 + (ch - 48)
  #|  }
  #|  turtles_finish_read(r)
  #|  n
  #|}
  #|

///|
priv struct SchemaRender {
  file : SchemaFile
  out : StringBuilder
  mut chars : Int32
  /// helper name -> helper source, collected for the package file
  helpers : Map[String, String]
}

///|
fn SchemaRender::emit(self : SchemaRender, text : String) -> Unit {
  self.out.write_string(text)
  self.chars = self.chars + text.char_length()
}

///|
fn SchemaRender::emit_source(
  self : SchemaRender,
  start : Int32,
  end : Int32,
) -> Unit {
  if end > start {
    self.emit(@utf8.decode_lossy(self.file.bytes[start:end]))
  }
}

///|
fn SchemaRender::hole(
  self : SchemaRender,
  hole : (Int32, Int32),
  inner : Array[Int32],
) -> Unit {
  let (start, end) = hole
  let contained = inner.filter(i => {
    let site = self.file.sites[i]
    site.start >= start && site.end <= end
  })
  self.range(start, end, contained)
}

///|
/// Render source `[start, end)` with every site in `indices` (sorted,
/// all inside the range) replaced by its template. Sites that fall
/// outside every hole of their parent are left unrendered and therefore
/// stay on the classic path.
fn SchemaRender::range(
  self : SchemaRender,
  start : Int32,
  end : Int32,
  indices : Array[Int32],
) -> Unit {
  let mut pos = start
  let mut k = 0
  while k < indices.length() {
    let index = indices[k]
    let site = self.file.sites[index]
    if site.start < pos {
      k = k + 1
      continue
    }
    let mut j = k + 1
    while j < indices.length() && self.file.sites[indices[j]].start < site.end {
      j = j + 1
    }
    let inner = indices[k + 1:j].to_array()
    self.emit_source(pos, site.start)
    site.gen_start = self.chars
    self.template(site, inner)
    site.gen_end = self.chars
    site.rendered = true
    pos = site.end
    k = j
  }
  self.emit_source(pos, end)
}

///|
fn SchemaRender::template(
  self : SchemaRender,
  site : SchemaSite,
  inner : Array[Int32],
) -> Unit {
  match site.kind {
    SiteInfix(op) => {
      let replacements = site.variants.map(v => v.replacement)
      let name = infix_helper_name(op, replacements).unwrap()
      if !self.helpers.contains(name) {
        self.helpers[name] = infix_helper_source(op, replacements)
      }
      self.emit("\{name}(")
      self.hole(site.holes[0], inner)
      self.emit(", ")
      self.hole(site.holes[1], inner)
      for variant in site.variants {
        self.emit(", \{variant.id}")
      }
      self.emit(")")
    }
    SiteBool(op) => {
      let cmp = if op == "&&" { "==" } else { "!=" }
      self.emit("({ let turtles_l = (")
      self.hole(site.holes[0], inner)
      self.emit(
        "); if turtles_l == (turtles_active() \{cmp} \{site.variants[0].id}) { turtles_l } else { (",
      )
      self.hole(site.holes[1], inner)
      self.emit(") } })")
    }
    SiteUnary => {
      self.helpers["turtles_op_neg"] = schemata_neg_helper
      self.emit("turtles_op_neg(")
      self.hole(site.holes[0], inner)
      self.emit(", \{site.variants[0].id})")
    }
    SiteLiteral(value) => {
      let cmp = if value { "!=" } else { "==" }
      self.emit("(turtles_active() \{cmp} \{site.variants[0].id})")
    }
    SiteCondition => {
      self.emit("(match turtles_active() { ")
      for variant in site.variants {
        self.emit("\{variant.id} => \{variant.replacement}; ")
      }
      self.emit("_ => (")
      self.hole(site.holes[0], inner)
      self.emit(") })")
    }
    SiteBody => {
      self.emit("match turtles_active() { ")
      for variant in site.variants {
        self.emit("\{variant.id} => { \{variant.replacement} }; ")
      }
      // The leading `();` keeps a bare-identifier body such as `{ a }`
      // from parsing as a punned record literal.
      self.emit("_ => { (); ")
      self.hole(site.holes[0], inner)
      self.emit(" } }")
    }
  }
}

///|
/// A site can be rendered only when every variant fits its template:
/// operator helpers need a known operator spelling, and the single-id
/// templates (`&&`/`||`, unary minus, literals) carry exactly one variant.
fn site_supported(site : SchemaSite) -> Bool {
  match site.kind {
    SiteInfix(op) =>
      infix_helper_name(op, site.variants.map(v => v.replacement)) is Some(_)
    SiteBool(_) | SiteUnary | SiteLiteral(_) => site.variants.length() == 1
    SiteCondition | SiteBody => true
  }
}

///|
/// Regenerate the file from the currently enabled sites; returns the
/// helper definitions its sites need.
fn SchemaFile::render(self : SchemaFile) -> Map[String, String] {
  let indices : Array[Int32] = []
  for i, site in self.sites {
    site.rendered = false
    if self.enabled[i] && site_supported(site) {
      indices.push(i)
    }
  }
  let render = SchemaRender::{
    file: self,
    out: StringBuilder(),
    chars: 0,
    helpers: Map([]),
  }
  render.range(0, self.bytes.length(), indices)
  self.generated = render.out.to_string()
  render.helpers
}

///|
/// Mutation ids actually present in the generated text.
fn SchemaFile::instrumented_ids(self : SchemaFile) -> Array[Int32] {
  let ids : Array[Int32] = []
  for i, site in self.sites {
    if self.enabled[i] && site.rendered {
      for variant in site.variants {
        ids.push(variant.id)
      }
    }
  }
  ids
}

///|
/// Disable the innermost rendered site whose generated range holds the
/// scalar `offset`; when none does, disable every site in the file.
/// Several diagnostics of one round can land in the same site, so the
/// search covers sites already disabled this round (rendered is from the
/// last render). Returns whether anything changed.
fn SchemaFile::reject_at(self : SchemaFile, offset : Int32?) -> Bool {
  let mut best : Int32? = None
  match offset {
    Some(offset) =>
      for i, site in self.sites {
        if site.rendered && site.gen_start <= offset && offset <= site.gen_end {
          match best {
            Some(b) => {
              let current = self.sites[b]
              if site.gen_end - site.gen_start <
                current.gen_end - current.gen_start {
                best = Some(i)
              }
            }
            None => best = Some(i)
          }
        }
      }
    None => ()
  }
  match best {
    Some(i) => {
      let changed = self.enabled[i]
      self.enabled[i] = false
      changed
    }
    None => self.reject_all()
  }
}

///|
fn SchemaFile::reject_all(self : SchemaFile) -> Bool {
  let mut changed = false
  for i, site in self.sites {
    if self.enabled[i] && site.rendered {
      changed = true
    }
    self.enabled[i] = false
  }
  changed
}

///|
/// Scalar offset of 1-based `line`:`column` in `text`.
fn line_column_offset(text : String, line : Int32, column : Int32) -> Int32? {
  guard line >= 1 && column >= 1 else { return None }
  let mut current = 1
  let mut offset = 0
  for ch in text {
    if current == line {
      break
    }
    if ch == '\n' {
      current = current + 1
    }
    offset = offset + 1
  }
  if current != line {
    return None
  }
  Some(offset + column - 1)
}

///|
priv struct CheckError {
  path : String
  line : Int32
  column : Int32
  message : String
}

///|
/// Error diagnostics from `moon check --output-json`; `loc` is
/// `"line:col-line:col"`, 1-based.
fn parse_check_errors(output : String) -> Array[CheckError] {
  let errors : Array[CheckError] = []
  for raw in output.split("\n") {
    let line = raw.trim().to_owned()
    guard line.has_prefix("{") else { continue }
    let json = @json.parse(line) catch { _ => continue }
    guard json is Object(fields) else { continue }
    guard fields.get("level") is Some(String("error")) else { continue }
    guard fields.get("path") is Some(String(path)) else { continue }
    let message = match fields.get("message") {
      Some(String(text)) => text
      _ => ""
    }
    let (l, c) = match fields.get("loc") {
      Some(String(loc)) => {
        let head = match loc.find("-") {
          Some(dash) => loc[:dash].to_owned()
          None => loc
        }
        let parts = head.split(":").map(part => part.to_owned()).to_array()
        if parts.length() == 2 {
          (
            @string.parse_int(parts[0]) catch {
              _ => 0
            },
            @string.parse_int(parts[1]) catch {
              _ => 0
            },
          )
        } else {
          (0, 0)
        }
      }
      _ => (0, 0)
    }
    errors.push({
      path: path.replace_all(old="\\", new="/"),
      line: l,
      column: c,
      message,
    })
  }
  errors
}

///|
fn path_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(i) => path[:i].to_owned()
    None => ""
  }
}

///|
/// All instrumented files plus one runtime/helper file per package.
priv struct Schemata {
  files : Array[SchemaFile]
  /// package dir -> helper names needed there (from the last render)
  mut package_helpers : Map[String, Map[String, String]]
}

///|
fn Schemata::render(self : Schemata) -> Unit {
  let packages : Map[String, Map[String, String]] = Map([])
  for file in self.files {
    let helpers = file.render()
    if file.instrumented_ids().is_empty() {
      continue
    }
    let dir = path_dir(file.path)
    let merged = match packages.get(dir) {
      Some(existing) => existing
      None => {
        let created : Map[String, String] = Map([])
        packages[dir] = created
        created
      }
    }
    for name, source in helpers {
      merged[name] = source
    }
  }
  self.package_helpers = packages
}

///|
fn schemata_helper_source(helpers : Map[String, String]) -> String {
  let names = helpers.keys().collect()
  names.sort()
  let out = StringBuilder()
  out.write_string(schemata_runtime)
  for name in names {
    out.write_string("\n")
    out.write_string(helpers[name])
  }
  out.to_string()
}

///|
fn Schemata::instrumented_ids(self : Schemata) -> Map[Int32, Bool] {
  let ids : Map[Int32, Bool] = Map([])
  for file in self.files {
    for id in file.instrumented_ids() {
      ids[id] = true
    }
  }
  ids
}

///|
/// Apply one round of check diagnostics; returns whether any site was
/// disabled. `rel` maps a diagnostic path to a module-relative path.
fn Schemata::reject_errors(
  self : Schemata,
  errors : Array[CheckError],
  rel : (String) -> String,
) -> Bool {
  let mut changed = false
  for error in errors {
    let path = rel(error.path)
    let mut matched = false
    for file in self.files {
      if file.path == path {
        matched = true
        let offset = line_column_offset(
          file.generated,
          error.line,
          error.column,
        )
        if file.reject_at(offset) {
          changed = true
        }
      }
    }
    if !matched &&
      (
        path.has_suffix("/" + schemata_helper_file) ||
        path == schemata_helper_file
      ) {
      let dir = path_dir(path)
      for file in self.files {
        if path_dir(file.path) == dir && file.reject_all() {
          changed = true
        }
      }
    }
  }
  changed
}

///|
/// Disable every site in packages whose directory is in `dirs`.
fn Schemata::reject_packages(self : Schemata, dirs : Array[String]) -> Bool {
  let mut changed = false
  for file in self.files {
    if dirs.contains(path_dir(file.path)) && file.reject_all() {
      changed = true
    }
  }
  changed
}

///|
fn build_schemata(
  sources : Map[String, String],
  mutations : Array[(Int32, Mutation)],
) -> Schemata {
  let by_path : Map[String, Array[(Int32, Mutation)]] = Map([])
  for entry in mutations {
    let path = entry.1.path
    match by_path.get(path) {
      Some(list) => list.push(entry)
      None => by_path[path] = [entry]
    }
  }
  let files : Array[SchemaFile] = []
  for path, entries in by_path {
    guard sources.get(path) is Some(source) else { continue }
    let file = build_schema_file(path, source, entries) catch { _ => continue }
    files.push(file)
  }
  let schemata = { files, package_helpers: Map([]), }
  schemata.render()
  schemata
}

///|
#cfg(platform="windows")
fn schemata_supported() -> Bool {
  false
}

///|
#cfg(not(platform="windows"))
fn schemata_supported() -> Bool {
  true
}

///|
/// Module-relative package dir of a test-failure `pkg` name.
fn kill_pkg_dir(module_name : String?, pkg : String) -> String {
  match module_name {
    Some(name) =>
      if pkg == name {
        ""
      } else if pkg.has_prefix(name + "/") {
        pkg[name.length() + 1:].to_owned()
      } else {
        pkg
      }
    None => pkg
  }
}

///|
/// Write the current render into the instrumented workspace: every
/// schema file (an all-rejected file goes back to its original text)
/// and one runtime/helper file per package that still has sites.
async fn write_schemata(
  workspace : String,
  schemata : Schemata,
  written : Map[String, Bool],
) -> Unit {
  for file in schemata.files {
    @fs.write_file(path_join(workspace, file.path), file.generated)
  }
  for dir, _ in written {
    if !schemata.package_helpers.contains(dir) {
      @fs.remove(
        path_join(path_join(workspace, dir), schemata_helper_file),
        allow_missing=true,
      )
    }
  }
  written.clear()
  for dir, helpers in schemata.package_helpers {
    @fs.write_file(
      path_join(path_join(workspace, dir), schemata_helper_file),
      schemata_helper_source(helpers),
    )
    written[dir] = true
  }
}

///|
/// Prepare the instrumented workspace. Returns the mutation ids that are
/// compiled in and the instrumented baseline test time, or None when no
/// site survived (every mutant then runs classic).
async fn prepare_schemata(
  workspace : String,
  reference : String,
  schemata : Schemata,
  timeout_ms : Int32,
  timeout_command : String?,
  target~ : String?,
) -> (Map[Int32, Bool], Int64, Int32)? {
  let workspace_real = @fs.realpath(workspace)
  let rel = (path : String) => {
    for prefix in [workspace_real + "/", workspace + "/"] {
      if path.has_prefix(prefix) {
        return path[prefix.length():].to_owned()
      }
    }
    path
  }
  let module_name = module_name_of(reference)
  let written : Map[String, Bool] = Map([])
  let mut rounds = 0
  for attempt in 0..<5 {
    ignore(attempt)
    let mut checked = false
    for round in 0..<64 {
      ignore(round)
      if schemata.instrumented_ids().is_empty() {
        println("--schemata: every site was rejected by `moon check`")
        break
      }
      rounds = rounds + 1
      write_schemata(workspace, schemata, written)
      match
        run_moon_command(
          workspace,
          ["check", "--output-json"],
          timeout_ms * 10,
          timeout_command,
          target~,
        ) {
        CommandSuccess => {
          checked = true
          break
        }
        CommandTimeout => {
          println("warning: --schemata: `moon check` timed out")
          break
        }
        CommandFailure => {
          let output = read_moon_output(workspace).unwrap_or("")
          let errors = parse_check_errors(output)
          if @env.get_env_var("TURTLES_SCHEMATA_DEBUG") is Some(_) {
            for error in errors {
              println(
                "  schemata check: \{rel(error.path)}:\{error.line}:\{error.column}: \{error.message}",
              )
            }
          }
          if !schemata.reject_errors(errors, rel) {
            let first = if errors.is_empty() {
              "no structured diagnostics"
            } else {
              "\{errors[0].path}:\{errors[0].line}: \{errors[0].message}"
            }
            println(
              "warning: --schemata: cannot attribute check failure (\{first})",
            )
            break
          }
          schemata.render()
        }
      }
    }
    if !checked {
      return None
    }
    // Mutant 0 is the original program: it must pass exactly like the
    // classic baseline, or the instrumentation itself changed behavior.
    let started = @async.now()
    match
      run_moon_command(
        workspace,
        mutant_test_args(None),
        timeout_ms * 10,
        timeout_command,
        target~,
        env=Map([(schemata_env_var, "0")]),
      ) {
      CommandSuccess =>
        return Some(
          (schemata.instrumented_ids(), @async.now() - started, rounds),
        )
      CommandTimeout => {
        println("warning: --schemata: instrumented baseline timed out")
        return None
      }
      CommandFailure => {
        let dirs = match last_test_failures(workspace) {
          Some(kills) => kills.map(kill => kill_pkg_dir(module_name, kill.pkg))
          None => []
        }
        println(
          "--schemata: instrumented baseline failed in \{dirs.length()} test(s); dropping those packages",
        )
        if !schemata.reject_packages(dirs) {
          return None
        }
        schemata.render()
      }
    }
  }
  None
}

///|
async fn schemata_warm(
  workspace : String,
  timeout_ms : Int32,
  timeout_command : String?,
  target~ : String?,
) -> Unit {
  match
    run_moon_command(
      workspace,
      ["test", "--build-only"],
      timeout_ms,
      timeout_command,
      target~,
    ) {
    CommandSuccess => ()
    _ => fail("--schemata: warm-up `moon test --build-only` failed")
  }
}

///|
/// Like `run_mutation_pool`, but every worker holds a copy of the
/// instrumented tree built once; a mutant is one `moon test` with
/// TURTLES_MUTANT set. Nothing is rewritten, so there is no check step:
/// every compiled-in mutant already type-checked.
async fn run_schemata_pool(
  temp : String,
  instrumented : String,
  items : Array[(Int32, Mutation)],
  jobs : Int32,
  plan : TestPlan?,
  test_timeout_ms : Int32,
  warm_timeout_ms : Int32,
  timeout_command : String?,
  target~ : String?,
) -> Array[(Int32, MutationResult)] {
  let total = items.length()
  let slots : Array[(Int32, MutationResult)?] = Array::make(total, None)
  let next_index = Ref(0)
  let completed = Ref(0)
  let worker_count = if jobs < total { jobs } else { total }
  @async.with_task_group(group => {
    for w in 0..<worker_count {
      let workspace = path_join(temp, "schemata-worker-\{w}")
      group.spawn_bg(() => {
        @fs.mkdir(workspace, recursive=true)
        copy_tree(instrumented, instrumented, workspace)
        schemata_warm(workspace, warm_timeout_ms, timeout_command, target~)
        let manifest = Ref(snapshot_workspace(workspace))
        while true {
          let index = next_index.val
          if index >= total {
            break
          }
          next_index.val = index + 1
          let (i, mutation) = items[index]
          let packages = match plan {
            Some(plan) => plan.test_packages_for(mutation)
            None => None
          }
          let started = @async.now()
          let (outcome, kills) = match
            run_moon_command(
              workspace,
              mutant_test_args(packages),
              test_timeout_ms,
              timeout_command,
              target~,
              env=Map([(schemata_env_var, (i + 1).to_string())]),
            ) {
            CommandSuccess => (Survived, None)
            CommandFailure => (Killed, last_test_failures(workspace))
            CommandTimeout => (Timeout, None)
          }
          let duration_ms = @async.now() - started
          sweep_workspace(workspace, instrumented, manifest.val) catch {
            _ => {
              manifest.val = rebuild_workspace(workspace, instrumented)
              schemata_warm(
                workspace,
                warm_timeout_ms,
                timeout_command,
                target~,
              )
            }
          }
          let result = {
            mutation,
            outcome,
            duration_ms,
            reused: false,
            packages,
            kills,
            witness: None,
            witness_skipped: None,
            amplified: None,
          }
          slots[index] = Some((i, result))
          completed.val = completed.val + 1
          println(
            "[\{completed.val}/\{total}] \{outcome_name(outcome)} \{describe_mutation(mutation)}\{describe_kills(result)}",
          )
        }
        force_rmdir(workspace) catch {
          _ => ()
        }
      })
    }
  })
  slots.map(slot => slot.unwrap())
}

///|
/// Schemata driver: instrument, check-and-drop until the tree compiles,
/// verify mutant 0 against the tests, then run compiled-in mutants from
/// the shared build and everything else through the classic pool.
/// Results come back in `mutations` order.
async fn run_schemata(
  temp : String,
  reference : String,
  mutations : Array[Mutation],
  reuse : Array[MutationResult?],
  jobs : Int32,
  plan : TestPlan?,
  timeout_ms : Int32,
  timeout_multiplier : Double?,
  baseline_check_ms : Int64,
  baseline_test_ms : Int64,
  timeout_command : String?,
  classify : async (String, Mutation) -> (Outcome, Array[String]?, Array[Kill]?),
  target~ : String? = None,
) -> Array[MutationResult] {
  let total = mutations.length()
  let entries : Array[(Int32, Mutation)] = []
  let sources : Map[String, String] = Map([])
  for i, mutation in mutations {
    if reuse[i] is Some(_) {
      continue
    }
    entries.push((i + 1, mutation))
    if !sources.contains(mutation.path) {
      sources[mutation.path] = @fs.read_file(
        path_join(reference, mutation.path),
      ).text()
    }
  }
  let started = @async.now()
  let workspace = path_join(temp, "schemata")
  @fs.mkdir(workspace, recursive=true)
  copy_tree(reference, reference, workspace)
  let schemata = build_schemata(sources, entries)
  println(
    "Schemata: instrumenting \{schemata.instrumented_ids().length()} mutant(s) in \{schemata.files.length()} file(s) ...",
  )
  let prepared = prepare_schemata(
    workspace,
    reference,
    schemata,
    timeout_ms,
    timeout_command,
    target~,
  )
  let (ids, schema_test_ms) = match prepared {
    Some((ids, test_ms, rounds)) => {
      println(
        "Schemata: \{ids.length()} mutant(s) compiled into one build after \{rounds} check round(s) in \{(@async.now() - started) / 1000}s; instrumented baseline \{test_ms / 1000}s",
      )
      (ids, test_ms)
    }
    None => {
      println("Schemata: no instrumented build; running every mutant classic")
      (Map([]), 0L)
    }
  }
  let schema_items : Array[(Int32, Mutation)] = []
  let classic_items : Array[Int32] = []
  for i, mutation in mutations {
    if reuse[i] is None && ids.contains(i + 1) {
      schema_items.push((i, mutation))
    } else {
      classic_items.push(i)
    }
  }
  let slots : Array[MutationResult?] = Array::make(total, None)
  if !schema_items.is_empty() {
    let test_base = if schema_test_ms > baseline_test_ms {
      schema_test_ms
    } else {
      baseline_test_ms
    }
    let (_, test_timeout_ms) = effective_timeouts(
      timeout_ms, timeout_multiplier, baseline_check_ms, test_base,
    )
    // A schemata mutant is nothing but a test run, and `jobs` of them run
    // at once, each as parallel as moon makes it. Under that contention a
    // run that took 32s alone was observed at 55-60s, so a fixed `--timeout`
    // turns ordinary kills into TIMEOUT. Without an explicit multiplier,
    // never allow less than 4x the measured (uncontended) suite time.
    let test_timeout_ms = if timeout_multiplier is None {
      let floor = (test_base * 4L).to_int()
      if floor > test_timeout_ms {
        floor
      } else {
        test_timeout_ms
      }
    } else {
      test_timeout_ms
    }
    println(
      "Schemata: running \{schema_items.length()} mutant(s) from the shared build (test timeout \{test_timeout_ms / 1000}s)",
    )
    let results = run_schemata_pool(
      temp,
      workspace,
      schema_items,
      jobs,
      plan,
      test_timeout_ms,
      timeout_ms * 10,
      timeout_command,
      target~,
    )
    for entry in results {
      slots[entry.0] = Some(entry.1)
    }
  }
  force_rmdir(workspace) catch {
    _ => ()
  }
  if !classic_items.is_empty() {
    println(
      "Schemata: running \{classic_items.length()} mutant(s) classic (rebuild per mutant)",
    )
    let results = run_mutation_pool(
      temp,
      reference,
      classic_items.map(i => mutations[i]),
      jobs,
      classic_items.map(i => reuse[i]),
      classify,
    )
    for k, i in classic_items {
      slots[i] = Some(results[k])
    }
  }
  slots.map(slot => slot.unwrap())
}
