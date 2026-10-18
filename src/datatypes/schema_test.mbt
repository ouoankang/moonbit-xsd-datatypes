// Tests for reading schemas out of real XSD documents.

///|
fn sample_schema() -> String {
  "<?xml version=\"1.0\"?>\n" +
  "<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">\n" +
  "  <xs:simpleType name=\"shortCode\">\n" +
  "    <xs:restriction base=\"xs:string\">\n" +
  "      <xs:maxLength value=\"3\"/>\n" +
  "      <xs:pattern value=\"[A-Z]+\"/>\n" +
  "    </xs:restriction>\n" +
  "  </xs:simpleType>\n" +
  "  <xs:simpleType name=\"percent\">\n" +
  "    <xs:restriction base=\"xs:decimal\">\n" +
  "      <xs:minInclusive value=\"0\"/>\n" +
  "      <xs:maxInclusive value=\"100\"/>\n" +
  "      <xs:fractionDigits value=\"2\"/>\n" +
  "    </xs:restriction>\n" +
  "  </xs:simpleType>\n" +
  "  <xs:simpleType name=\"colour\">\n" +
  "    <xs:restriction base=\"xs:token\">\n" +
  "      <xs:enumeration value=\"red\"/>\n" +
  "      <xs:enumeration value=\"green\"/>\n" +
  "      <xs:enumeration value=\"blue\"/>\n" +
  "    </xs:restriction>\n" +
  "  </xs:simpleType>\n" +
  "  <xs:simpleType name=\"tags\">\n" +
  "    <xs:list itemType=\"xs:NMTOKEN\"/>\n" +
  "  </xs:simpleType>\n" +
  "  <xs:simpleType name=\"numOrDate\">\n" +
  "    <xs:union memberTypes=\"xs:int xs:date\"/>\n" +
  "  </xs:simpleType>\n" +
  "  <xs:element name=\"code\" type=\"shortCode\"/>\n" +
  "</xs:schema>"
}

///|
fn schema() -> Schema {
  match load_schema(sample_schema()) {
    Ok(s) => s
    Err(e) => abort("schema should load: \{e}")
  }
}

///|
fn accepts(s : Schema, name : String, value : String) -> Bool {
  match validate_named(s, name, value) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
test "schema loads and declares five types" {
  let s = schema()
  assert_true(s.get("shortCode") is Some(_))
  assert_true(s.get("percent") is Some(_))
  assert_true(s.get("colour") is Some(_))
  assert_true(s.get("tags") is Some(_))
  assert_true(s.get("numOrDate") is Some(_))
}

///|
test "maxLength and pattern both apply" {
  let s = schema()
  assert_true(accepts(s, "shortCode", "ABC"))
  assert_false(accepts(s, "shortCode", "ABCD"))
  assert_false(accepts(s, "shortCode", "abc"))
  // `A1` is VALID: XSD's pattern is a search, not an anchor, so the single
  // letter `A` satisfies `[A-Z]+`. Writing `[A-Z]+` expecting a whole-string
  // match is the classic XSD mistake, and a validator that anchors here would
  // be wrong.
  assert_true(accepts(s, "shortCode", "A1"))
  // To reject, the value must contain no match at all.
  assert_false(accepts(s, "shortCode", "123"))
}

///|
test "numeric bounds and fractionDigits" {
  let s = schema()
  assert_true(accepts(s, "percent", "0"))
  assert_true(accepts(s, "percent", "100"))
  assert_true(accepts(s, "percent", "99.99"))
  assert_false(accepts(s, "percent", "100.01"))
  assert_false(accepts(s, "percent", "-0.01"))
  assert_false(accepts(s, "percent", "1.234"))
}

///|
test "enumeration on a token type" {
  let s = schema()
  assert_true(accepts(s, "colour", "red"))
  assert_true(accepts(s, "colour", "  blue  "))
  assert_false(accepts(s, "colour", "purple"))
}

///|
test "list type splits on whitespace" {
  let s = schema()
  assert_true(accepts(s, "tags", "a b c"))
  assert_true(accepts(s, "tags", "  a   b  "))
  assert_false(accepts(s, "tags", "a b!"))
  assert_false(accepts(s, "tags", ""))
}

///|
test "union accepts either member" {
  let s = schema()
  assert_true(accepts(s, "numOrDate", "7"))
  assert_true(accepts(s, "numOrDate", "2026-10-18"))
  assert_false(accepts(s, "numOrDate", "2026-02-30"))
  assert_false(accepts(s, "numOrDate", "seven"))
}

///|
test "unknown type name is rejected" {
  let s = schema()
  match validate_named(s, "missing", "x") {
    Ok(_) => abort("expected an error")
    Err(_) => ()
  }
}

///|
test "a non-schema root is rejected" {
  match load_schema("<a/>") {
    Ok(_) => abort("expected an error")
    Err(_) => ()
  }
}

///|
test "malformed XML is rejected" {
  match load_schema("<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\">") {
    Ok(_) => abort("expected an error")
    Err(_) => ()
  }
}

///|
test "pattern facet applies on its own" {
  let f = Facets::{
    length: None,
    min_length: None,
    max_length: None,
    patterns: ["[A-Z]+"],
    enumeration: Array(capacity=0),
    max_inclusive: None,
    max_exclusive: None,
    min_inclusive: None,
    min_exclusive: None,
    total_digits: None,
    fraction_digits: None,
  }
  let t = make_atomic_with("string", f)
  let passes = fn(s : String) -> Bool {
    match check_value(t, s) {
      Ok(_) => true
      Err(_) => false
    }
  }
  assert_true(passes("ABC"))
  assert_false(passes("abc"))
}
