// Tests for the datatype layer.
//
// The cases are chosen where a naive implementation is wrong, not where the
// happy path is obvious: `xs:integer` rejecting `1.0`, February 30th being a
// lexical-space member by shape but not by value, `INF` being case-sensitive,
// and `pattern` searching rather than anchoring.

///|
fn ok(t : String, s : String) -> Bool {
  is_valid_lexical(t, s)
}

///|
test "string preserves whitespace, normalizedString replaces it" {
  assert_true(ok("string", "  a  b  "))
  let v = validate_builtin("string", "  a  b  ")
  match v {
    Ok(Str(s)) => assert_eq(s, "  a  b  ")
    _ => abort("expected a string value")
  }
  match validate_builtin("normalizedString", "a\tb") {
    Ok(Str(s)) => assert_eq(s, "a b")
    _ => abort("expected a string value")
  }
  match validate_builtin("token", "  a   b  ") {
    Ok(Str(s)) => assert_eq(s, "a b")
    _ => abort("expected a string value")
  }
}

///|
test "decimal accepts leading dot and trailing dot" {
  assert_true(ok("decimal", "1"))
  assert_true(ok("decimal", "1.0"))
  assert_true(ok("decimal", ".5"))
  assert_true(ok("decimal", "1."))
  assert_true(ok("decimal", "-0.001"))
  assert_true(ok("decimal", "+42"))
}

///|
test "decimal rejects exponents and infinities" {
  // These belong to float/double only; accepting them here is a common bug.
  assert_false(ok("decimal", "1e3"))
  assert_false(ok("decimal", "1E3"))
  assert_false(ok("decimal", "INF"))
  assert_false(ok("decimal", "NaN"))
  assert_false(ok("decimal", "--1"))
  assert_false(ok("decimal", "1.2.3"))
  assert_false(ok("decimal", " "))
}

///|
test "integer rejects a decimal point" {
  assert_true(ok("integer", "42"))
  assert_true(ok("integer", "-42"))
  assert_true(ok("integer", "+007"))
  assert_false(ok("integer", "1.0"))
  assert_false(ok("integer", "1."))
  assert_false(ok("integer", "1e3"))
}

///|
test "integer subtype ranges" {
  assert_true(ok("byte", "127"))
  assert_true(ok("byte", "-128"))
  assert_false(ok("byte", "128"))
  assert_false(ok("byte", "-129"))
  assert_true(ok("unsignedByte", "255"))
  assert_false(ok("unsignedByte", "256"))
  assert_false(ok("unsignedByte", "-1"))
  assert_true(ok("short", "32767"))
  assert_false(ok("short", "32768"))
  assert_true(ok("int", "2147483647"))
  assert_false(ok("int", "2147483648"))
  assert_true(ok("long", "9223372036854775807"))
  assert_false(ok("long", "9223372036854775808"))
}

///|
test "sign-constrained integers" {
  assert_true(ok("nonNegativeInteger", "0"))
  assert_false(ok("nonNegativeInteger", "-1"))
  assert_true(ok("positiveInteger", "1"))
  assert_false(ok("positiveInteger", "0"))
  assert_true(ok("nonPositiveInteger", "0"))
  assert_false(ok("nonPositiveInteger", "1"))
  assert_true(ok("negativeInteger", "-1"))
  assert_false(ok("negativeInteger", "0"))
}

///|
test "boolean lexical space is exactly four words" {
  assert_true(ok("boolean", "true"))
  assert_true(ok("boolean", "false"))
  assert_true(ok("boolean", "1"))
  assert_true(ok("boolean", "0"))
  assert_false(ok("boolean", "TRUE"))
  assert_false(ok("boolean", "True"))
  assert_false(ok("boolean", "yes"))
  assert_false(ok("boolean", ""))
}

///|
test "float special values are case sensitive" {
  assert_true(ok("float", "NaN"))
  assert_true(ok("float", "INF"))
  assert_true(ok("float", "-INF"))
  assert_true(ok("float", "+INF"))
  assert_false(ok("float", "nan"))
  assert_false(ok("float", "inf"))
  assert_false(ok("float", "Infinity"))
  assert_true(ok("double", "1.5e10"))
  assert_true(ok("double", "-0.0"))
  assert_false(ok("double", "1e"))
  assert_false(ok("double", "1e+"))
}

///|
test "hexBinary needs an even number of hex digits" {
  assert_true(ok("hexBinary", "0FB7"))
  assert_true(ok("hexBinary", ""))
  assert_false(ok("hexBinary", "0F3"))
  assert_false(ok("hexBinary", "0G"))
}

///|
test "base64Binary accepts whitespace and both padding forms" {
  assert_true(ok("base64Binary", "aGVsbG8="))
  assert_true(ok("base64Binary", "aGVs bG8="))
  assert_false(ok("base64Binary", "aGVsbG8"))
  assert_false(ok("base64Binary", "aGVsbG8=x"))
}

///|
test "date rejects impossible days" {
  assert_true(ok("date", "2026-02-28"))
  assert_true(ok("date", "2024-02-29"))
  assert_false(ok("date", "2026-02-29"))
  assert_false(ok("date", "2026-02-30"))
  assert_false(ok("date", "2026-13-01"))
  assert_false(ok("date", "2026-04-31"))
  assert_true(ok("date", "2026-12-31Z"))
  assert_true(ok("date", "2026-12-31+08:00"))
}

///|
test "time allows 24:00:00 and nothing else in hour 24" {
  assert_true(ok("time", "00:00:00"))
  assert_true(ok("time", "23:59:59"))
  assert_true(ok("time", "24:00:00"))
  assert_false(ok("time", "24:00:01"))
  assert_false(ok("time", "24:01:00"))
  assert_false(ok("time", "25:00:00"))
  assert_true(ok("time", "12:30:00.500"))
  assert_true(ok("time", "12:30:00Z"))
}

///|
test "dateTime requires a T separator" {
  assert_true(ok("dateTime", "2026-10-18T12:00:00"))
  assert_true(ok("dateTime", "2026-10-18T12:00:00.123Z"))
  assert_true(ok("dateTime", "2026-10-18T12:00:00-05:00"))
  assert_false(ok("dateTime", "2026-10-18 12:00:00"))
  assert_false(ok("dateTime", "2026-10-18"))
}

///|
test "timezone offset is bounded at 14 hours" {
  assert_true(ok("dateTime", "2026-01-01T00:00:00+14:00"))
  assert_false(ok("dateTime", "2026-01-01T00:00:00+14:30"))
  assert_false(ok("dateTime", "2026-01-01T00:00:00+15:00"))
}

///|
test "gMonthDay knows about February 29th" {
  assert_true(ok("gMonthDay", "--02-29"))
  assert_false(ok("gMonthDay", "--02-30"))
  assert_true(ok("gMonthDay", "--12-31"))
}

///|
test "duration needs at least one field and a T before times" {
  assert_true(ok("duration", "P1Y"))
  assert_true(ok("duration", "P1Y2M3DT4H5M6S"))
  assert_true(ok("duration", "-P1D"))
  assert_true(ok("duration", "PT0.5S"))
  assert_false(ok("duration", "P"))
  assert_false(ok("duration", "PT"))
  assert_false(ok("duration", "1Y"))
  assert_false(ok("duration", "P1D2Y"))
}

///|
test "QName shape" {
  assert_true(ok("QName", "amount"))
  assert_true(ok("QName", "xs:amount"))
  assert_false(ok("QName", "xs:"))
  assert_false(ok("QName", ":amount"))
  assert_false(ok("QName", "a:b:c"))
  assert_false(ok("QName", "1abc"))
}

///|
test "language tag shape" {
  assert_true(ok("language", "zh"))
  assert_true(ok("language", "zh-Hans"))
  assert_true(ok("language", "en-US"))
  assert_true(ok("language", "zh-Hans-CN-x"))
  assert_false(ok("language", "zh-"))
  assert_false(ok("language", "-zh"))
  assert_false(ok("language", ""))
  assert_false(ok("language", "123"))
}

///|
test "length facet counts code points" {
  let f = Facets::{
    length: Some(3),
    min_length: None,
    max_length: None,
    patterns: Array(capacity=0),
    enumeration: Array(capacity=0),
    max_inclusive: None,
    max_exclusive: None,
    min_inclusive: None,
    min_exclusive: None,
    total_digits: None,
    fraction_digits: None,
  }
  let t = make_atomic_with("string", f)
  assert_true(
    match check_value(t, "abc") {
      Ok(_) => true
      Err(_) => false
    },
  )
  assert_false(
    match check_value(t, "abcd") {
      Ok(_) => true
      Err(_) => false
    },
  )
}

///|
test "minInclusive and maxExclusive on decimal" {
  let f = Facets::{
    length: None,
    min_length: None,
    max_length: None,
    patterns: Array(capacity=0),
    enumeration: Array(capacity=0),
    max_inclusive: None,
    max_exclusive: Some(Dec(decimal_of(false, "10", ""))),
    min_inclusive: Some(Dec(decimal_of(true, "1", ""))),
    min_exclusive: None,
    total_digits: None,
    fraction_digits: None,
  }
  let t = make_atomic_with("decimal", f)
  let passes = fn(s : String) -> Bool {
    match check_value(t, s) {
      Ok(_) => true
      Err(_) => false
    }
  }
  assert_true(passes("-1"))
  assert_false(passes("-1.1"))
  assert_true(passes("9.99"))
  assert_false(passes("10"))
}

///|
test "totalDigits and fractionDigits on decimal" {
  let f = Facets::{
    length: None,
    min_length: None,
    max_length: None,
    patterns: Array(capacity=0),
    enumeration: Array(capacity=0),
    max_inclusive: None,
    max_exclusive: None,
    min_inclusive: None,
    min_exclusive: None,
    total_digits: Some(3),
    fraction_digits: Some(1),
  }
  let t = make_atomic_with("decimal", f)
  let passes = fn(s : String) -> Bool {
    match check_value(t, s) {
      Ok(_) => true
      Err(_) => false
    }
  }
  assert_true(passes("12.3"))
  assert_true(passes("100"))
  assert_false(passes("1234"))
  assert_false(passes("1.23"))
}

///|
test "enumeration compares values, not spellings" {
  let f = Facets::{
    length: None,
    min_length: None,
    max_length: None,
    patterns: Array(capacity=0),
    enumeration: [Dec(decimal_of(false, "1", ""))],
    max_inclusive: None,
    max_exclusive: None,
    min_inclusive: None,
    min_exclusive: None,
    total_digits: None,
    fraction_digits: None,
  }
  let t = make_atomic_with("decimal", f)
  let passes = fn(s : String) -> Bool {
    match check_value(t, s) {
      Ok(_) => true
      Err(_) => false
    }
  }
  // 1 and 1.0 are the same decimal value.
  assert_true(passes("1"))
  assert_true(passes("1.0"))
  assert_true(passes("+1.00"))
  assert_false(passes("2"))
}

///|
test "pattern facet searches rather than anchors" {
  // XSD's pattern is a search: a value is valid if the expression matches
  // somewhere inside it.
  assert_true(xsd_pattern_search("[0-9]+", "abc123def"))
  assert_false(xsd_pattern_search("[0-9]+", "abcdef"))
  // Anchoring needs an explicit whole-string match.
  assert_true(xsd_pattern_full_match("[0-9]+", "123"))
  assert_false(xsd_pattern_full_match("[0-9]+", "abc123"))
}

///|
test "xsd regex basics" {
  assert_true(xsd_pattern_full_match("a+", "aaa"))
  assert_false(xsd_pattern_full_match("a+", ""))
  assert_true(xsd_pattern_full_match("a?b", "b"))
  assert_true(xsd_pattern_full_match("(ab|cd)+", "abcdab"))
  assert_true(xsd_pattern_full_match("[a-z]{2,3}", "abc"))
  assert_false(xsd_pattern_full_match("[a-z]{2,3}", "a"))
  assert_true(xsd_pattern_full_match("\\d{4}-\\d{2}", "2026-10"))
  assert_true(xsd_pattern_full_match("[^0-9]+", "abc"))
  assert_true(xsd_pattern_full_match("a\\.b", "a.b"))
  assert_false(xsd_pattern_full_match("a\\.b", "axb"))
}

///|
test "xsd regex dot excludes line terminators" {
  assert_true(xsd_pattern_full_match("a.c", "abc"))
  assert_false(xsd_pattern_full_match("a.c", "a\nc"))
}

///|
test "list type counts items for length" {
  let f = Facets::{
    length: None,
    min_length: Some(2),
    max_length: Some(3),
    patterns: Array(capacity=0),
    enumeration: Array(capacity=0),
    max_inclusive: None,
    max_exclusive: None,
    min_inclusive: None,
    min_exclusive: None,
    total_digits: None,
    fraction_digits: None,
  }
  let t = make_list("NMTOKEN", f)
  let passes = fn(s : String) -> Bool {
    match check_value(t, s) {
      Ok(_) => true
      Err(_) => false
    }
  }
  assert_true(passes("a b"))
  assert_true(passes("a b c"))
  assert_false(passes("a"))
  assert_false(passes("a b c d"))
}

///|
test "union takes the first member that accepts" {
  let t = make_union(["int", "date"], no_facets())
  assert_true(
    match check_value(t, "42") {
      Ok(_) => true
      Err(_) => false
    },
  )
  assert_true(
    match check_value(t, "2026-10-18") {
      Ok(_) => true
      Err(_) => false
    },
  )
  assert_false(
    match check_value(t, "2026-02-30") {
      Ok(_) => true
      Err(_) => false
    },
  )
}

///|
test "temporal ordering respects timezones" {
  let a = match validate_builtin("dateTime", "2026-01-01T00:00:00Z") {
    Ok(Temporal(t)) => t
    _ => abort("expected a temporal value")
  }
  let b = match validate_builtin("dateTime", "2026-01-01T08:00:00+08:00") {
    Ok(Temporal(t)) => t
    _ => abort("expected a temporal value")
  }
  // Both denote the same instant.
  assert_eq(compare_temporal(a, b), 0)
}

///|
test "decimal normalization collapses equivalent spellings" {
  let a = match validate_builtin("decimal", "1.500") {
    Ok(Dec(d)) => d
    _ => abort("expected a decimal")
  }
  let b = match validate_builtin("decimal", "1.5") {
    Ok(Dec(d)) => d
    _ => abort("expected a decimal")
  }
  assert_eq(compare_decimal(a, b), 0)
  assert_eq(decimal_to_string(a), "1.5")
  assert_eq(total_digits(a), 2)
}

///|
test "negative zero is not negative" {
  let d = match validate_builtin("decimal", "-0.000") {
    Ok(Dec(d)) => d
    _ => abort("expected a decimal")
  }
  assert_false(d.negative)
  assert_eq(decimal_to_string(d), "0")
}

///|
test "builtin_local_name strips xs and xsd only" {
  assert_eq(builtin_local_name("xs:date"), Some("date"))
  assert_eq(builtin_local_name("xsd:date"), Some("date"))
  assert_eq(builtin_local_name("date"), Some("date"))
  assert_eq(builtin_local_name("my:date"), None)
}
