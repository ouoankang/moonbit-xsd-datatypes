// Runs the extracted W3C conformance cases.
//
// Each case is a schema document plus an element instance that the suite marks
// valid or invalid. A case passes when this validator agrees with the suite.

///|
/// One conformance run result.
struct W3cRun {
  total : Int
  agreed : Int
  schema_errors : Int
  /// (case index, expected, got) for the first few mismatches.
  mismatches : Array[(Int, Bool, Bool)]
  /// (case index, message) for the first few schema failures.
  schema_failures : Array[(Int, String)]
} derive(Debug)

///|
fn run_w3c_cases() -> W3cRun {
  let total = @datatypes.w3c_cases.length()
  let mut agreed = 0
  let mut schema_errors = 0
  let mismatches : Array[(Int, Bool, Bool)] = Array(capacity=0)
  let schema_failures : Array[(Int, String)] = Array(capacity=0)
  let mut i = 0
  for case in @datatypes.w3c_cases {
    let (schema_src, element, value, expected) = case
    match @datatypes.load_schema(schema_src) {
      Err(e) => {
        schema_errors = schema_errors + 1
        if schema_failures.length() < 10 {
          schema_failures.push((i, e.to_string()))
        }
      }
      Ok(schema) => {
        let got = match @datatypes.validate_element(schema, element, value) {
          Ok(_) => true
          Err(_) => false
        }
        if got == expected {
          agreed = agreed + 1
        } else if mismatches.length() < 8 {
          mismatches.push((i, expected, got))
        }
      }
    }
    i = i + 1
  }
  { total, agreed, schema_errors, mismatches, schema_failures }
}

///|
test "w3c conformance slice" {
  let r = run_w3c_cases()
  println(
    "w3c cases: \{r.agreed}/\{r.total} agreed, \{r.schema_errors} schema errors",
  )
  for m in r.mismatches {
    let (idx, expected, got) = m
    let (_, element, value, _) = @datatypes.w3c_cases[idx]
    println(
      "  mismatch #\{idx}: element=\{element} value=\"\{value}\" expected=\{expected} got=\{got}",
    )
  }
  for f in r.schema_failures {
    let (idx, msg) = f
    let (_, element, _, _) = @datatypes.w3c_cases[idx]
    println("  schema #\{idx} (\{element}): \{msg}")
  }
  // Every schema in the slice must parse: a failure there means the schema
  // reader regressed, not that the validator disagrees on a value.
  assert_eq(r.schema_errors, 0)
  // Every case must agree. The one place where this could drift is QName's
  // `length` facet, which XSD deprecates and never defines a measurement for;
  // see length_is_deprecated in facets.mbt.
  assert_eq(r.agreed, r.total)
}
