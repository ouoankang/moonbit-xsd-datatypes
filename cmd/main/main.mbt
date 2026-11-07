// Command line front end.
//
//   moon run cmd/main -- <type> <value>...   validate values against a built-in
//   moon run cmd/main -- --list              list the built-in type names
//   moon run cmd/main -- --schema <f.xsd> <type> <value>...
//
// The tool prints one line per value and does not set an exit status: the
// runtime this module targets exposes no way to choose one. Callers should read
// the output, where every line starts with `valid` or `INVALID`.

///|
/// Does this look like the path the runtime was launched with, rather than an
/// argument the user wrote?
///
/// `@env.args()` is not normalised across back ends: node puts the script path
/// at argv[0], the wasm runner puts the module path there, and native puts the
/// executable. Assuming a fixed offset is wrong on at least one of them, and
/// guessing from "does any argument start with --" breaks every invocation that
/// has no option, including `-- dateTime 2026-02-30` and any `gMonth` value
/// (whose lexical form is `--MM--`).
///
/// A path is recognisable on its own: no type name and no value in this tool's
/// grammar contains a separator or ends in a runtime's extension.
fn looks_like_program_path(s : String) -> Bool {
  s.contains("/") ||
  s.contains("\\") ||
  s.has_suffix(".js") ||
  s.has_suffix(".mjs") ||
  s.has_suffix(".wasm") ||
  s.has_suffix(".exe")
}

///|
fn usage() -> Unit {
  println("moonbit-xsd-datatypes")
  println("")
  println(
    "  <type> <value>     validate one or more values against a built-in type",
  )
  println("  --list             list built-in type names")
  println("  --types            same as --list")
  println("")
  println("examples:")
  println("  ... -- dateTime 2026-02-30T00:00:00")
  println("  ... -- decimal 1.5 2 3.25")
}

///|
fn builtin_type_names() -> Array[String] {
  [
    "string", "boolean", "decimal", "float", "double", "duration", "dateTime", "time",
    "date", "gYearMonth", "gYear", "gMonthDay", "gDay", "gMonth", "hexBinary", "base64Binary",
    "anyURI", "QName", "NOTATION", "normalizedString", "token", "language", "NMTOKEN",
    "NMTOKENS", "Name", "NCName", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES",
    "integer", "nonPositiveInteger", "negativeInteger", "long", "int", "short", "byte",
    "nonNegativeInteger", "unsignedLong", "unsignedInt", "unsignedShort", "unsignedByte",
    "positiveInteger",
  ]
}

///|
fn main {
  let args = @env.args()
  // Skip the interpreter or module path when the runtime supplied one. Some
  // runtimes supply both (node does, as `node <script> ...`), so this looks at
  // the first two positions rather than assuming a single fixed offset.
  let mut start = 0
  while start < args.length() &&
        start < 2 &&
        looks_like_program_path(args[start]) {
    start = start + 1
  }
  let argv : Array[String] = []
  let mut i = start
  while i < args.length() {
    argv.push(args[i])
    i = i + 1
  }
  if argv.is_empty() {
    usage()
    return
  }
  if argv[0] == "--list" || argv[0] == "--types" {
    for name in builtin_type_names() {
      println(name)
    }
    return
  }
  if argv[0] == "--schema" {
    if argv.length() < 4 {
      println("usage: --schema <file.xsd> <typeName> <value>...")
      return
    }
    let path = argv[1]
    let source = @fs.read_file_to_string(path) catch {
      _ => {
        println("cannot read \{path}")
        return
      }
    }
    let schema = match @dt.load_schema(source) {
      Ok(s) => s
      Err(e) => {
        println("schema error: \{e}")
        return
      }
    }
    let type_name = argv[2]
    let mut bad = 0
    let mut k = 3
    while k < argv.length() {
      let value = argv[k]
      match @dt.validate_named(schema, type_name, value) {
        Ok(v) =>
          println("valid    \{type_name}  \{value}  =>  \{@dt.lexical_text(v)}")
        Err(e) => {
          println("INVALID  \{type_name}  \{value}  =>  \{e}")
          bad = bad + 1
        }
      }
      k = k + 1
    }
    if bad > 0 {
      println("\{bad} value(s) invalid")
    } else {
      println("all values valid")
    }
    return
  }
  if argv.length() < 2 {
    usage()
    return
  }
  let type_name = argv[0]
  let mut failures = 0
  let mut k = 1
  while k < argv.length() {
    let value = argv[k]
    match @dt.validate_builtin(type_name, value) {
      Ok(v) =>
        println("valid    \{type_name}  \{value}  =>  \{@dt.lexical_text(v)}")
      Err(e) => {
        println("INVALID  \{type_name}  \{value}  =>  \{e}")
        failures = failures + 1
      }
    }
    k = k + 1
  }
  if failures > 0 {
    println("\{failures} value(s) invalid")
  } else {
    println("all values valid")
  }
}
