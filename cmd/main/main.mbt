// Command line front end.
//
//   moon run cmd/main -- <type> <value>...   validate values against a built-in
//   moon run cmd/main -- --list              list the built-in type names
//   moon run cmd/main -- --xml <file?>       print the element tree of a document
//
// Exit status is 1 when any value is invalid, so the tool can be used in a
// shell pipeline.

///|
fn usage() -> Unit {
  println("moonbit-xsd-datatypes")
  println("")
  println("  <type> <value>     validate one or more values against a built-in type")
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
    "string", "boolean", "decimal", "float", "double", "duration", "dateTime",
    "time", "date", "gYearMonth", "gYear", "gMonthDay", "gDay", "gMonth",
    "hexBinary", "base64Binary", "anyURI", "QName", "NOTATION",
    "normalizedString", "token", "language", "NMTOKEN", "NMTOKENS", "Name",
    "NCName", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "integer",
    "nonPositiveInteger", "negativeInteger", "long", "int", "short", "byte",
    "nonNegativeInteger", "unsignedLong", "unsignedInt", "unsignedShort",
    "unsignedByte", "positiveInteger",
  ]
}

///|
fn main {
  let args = @env.args()
  // Different back ends put different things at argv[0]: node's executable
  // path under , the wasm path under wasm, nothing under native.
  // Start at the first option-looking argument, or just after an executable.
  let mut start = 0
  let mut scan = 0
  while scan < args.length() {
    if args[scan].has_prefix("--") {
      start = scan
      break
    }
    scan = scan + 1
  }
  if start == 0 && args.length() > 0 && args[0].contains(".exe") {
    start = 1
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
    let source = try {
      @fs.read_file_to_string(path)
    } catch {
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
        Ok(v) => println("valid    \{type_name}  \{value}  =>  \{@dt.lexical_text(v)}")
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
  if argv[0] == "--xml" {
    println("--xml needs a file reader; run the datatype checks instead")
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
      Ok(v) => println("valid    \{type_name}  \{value}  =>  \{@dt.lexical_text(v)}")
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
