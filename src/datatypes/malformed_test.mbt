// Malformed and boundary inputs.
//
// The happy path is covered next to the implementation. What lives here is the
// other half: values that look plausible and must still be refused, and the
// fields where a parser is most likely to accept something it should not.
//
// The year rules in the first two tests are the ones a purely numeric check
// misses, because both are constraints on the value space rather than on the
// shape of the numeral.

///|
fn valid(t : String, s : String) -> Bool {
  @datatypes.is_valid_lexical(t, s)
}

///|
test "year 0000 does not exist; -0001 is 1 BCE" {
  // XSD 1.0 Part 2 §3.2.7: "There is no year 0, and '0000' is not a valid
  // lexical representation. '-0001' is the lexical representation of the year
  // 1 BCE." XSD 1.1 changed this; this module targets 1.0.
  assert_false(valid("date", "0000-01-01"))
  assert_false(valid("dateTime", "0000-01-01T00:00:00"))
  assert_false(valid("gYear", "0000"))
  assert_false(valid("gYearMonth", "0000-01"))
  assert_true(valid("date", "-0001-01-01"))
  assert_true(valid("gYear", "-0001"))
}

///|
test "a year past four digits may not carry leading zeros" {
  assert_false(valid("date", "00042-01-01"))
  assert_false(valid("gYear", "02026"))
  // 12345 is a legal year; this implementation stops at 9999 and says so in
  // the error rather than pretending the lexical form is malformed.
  assert_false(valid("date", "12345-01-01"))
}

///|
test "date fields must be complete and in range" {
  assert_false(valid("date", ""))
  assert_false(valid("date", "2026-1-01"))
  assert_false(valid("date", "2026-01-1"))
  assert_false(valid("date", "2026/01/01"))
  assert_false(valid("date", "2026-13-01"))
  assert_false(valid("date", "2026-00-10"))
  assert_false(valid("date", "2026-01-00"))
  assert_false(valid("date", "2026-01-01T"))
  // whiteSpace for date is collapse, so surrounding blanks are not a lexical
  // error: the value is the trimmed form.
  assert_true(valid("date", "  2026-01-01  "))
}

///|
test "timezone offsets are bounded and complete" {
  assert_true(valid("dateTime", "2026-01-01T00:00:00Z"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00z"))
  assert_true(valid("dateTime", "2026-01-01T00:00:00+14:00"))
  assert_true(valid("dateTime", "2026-01-01T00:00:00-14:00"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00+14:01"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00-15:00"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00+1:00"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00+01:0"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00+01:60"))
}

///|
test "time fields must be complete and in range" {
  assert_true(valid("time", "00:00:00"))
  assert_true(valid("time", "24:00:00"))
  assert_true(valid("time", "23:59:59.999"))
  assert_false(valid("time", "24:00"))
  assert_false(valid("time", "2:00:00"))
  assert_false(valid("time", "24:00:00.5"))
  assert_false(valid("time", "00:00:00."))
  assert_false(valid("time", "00:60:00"))
  assert_false(valid("time", "00:00:61"))
}

///|
test "partial dates reject impossible field values" {
  // --02-29 is legal: the type carries no year, so a leap year is assumed.
  assert_true(valid("gMonthDay", "--02-29"))
  assert_false(valid("gMonthDay", "--02-30"))
  assert_false(valid("gMonthDay", "--13-01"))
  assert_false(valid("gMonthDay", "--04-31"))
  assert_true(valid("gDay", "---31"))
  assert_false(valid("gDay", "---32"))
  assert_false(valid("gDay", "---00"))
  assert_true(valid("gMonth", "--12"))
  assert_false(valid("gMonth", "--00"))
  // `--MM--` is the form the first edition of the specification printed by
  // mistake; erratum E2-12 corrected it and rules it out.
  assert_false(valid("gMonth", "--12--"))
  assert_true(valid("gMonth", "--12-05:00"))
  assert_true(valid("gMonth", "--12Z"))
  assert_false(valid("gYearMonth", "2026-13"))
}

///|
test "duration needs at least one component and a unit" {
  assert_true(valid("duration", "P0D"))
  assert_true(valid("duration", "PT0S"))
  assert_true(valid("duration", "P1Y2M3DT4H5M6.7S"))
  assert_false(valid("duration", "P"))
  assert_false(valid("duration", "PT"))
  assert_false(valid("duration", "1D"))
  assert_false(valid("duration", "P-1D"))
  assert_false(valid("duration", "P1D2H"))
}

///|
test "binary types reject odd lengths and broken padding" {
  assert_true(valid("hexBinary", ""))
  assert_true(valid("hexBinary", "0f"))
  assert_false(valid("hexBinary", "ABC"))
  assert_false(valid("hexBinary", "GG"))
  assert_true(valid("base64Binary", ""))
  assert_true(valid("base64Binary", "AA=="))
  assert_false(valid("base64Binary", "A"))
  assert_false(valid("base64Binary", "AA="))
}

///|
test "names reject empty and malformed forms" {
  assert_false(valid("NCName", ""))
  assert_false(valid("NCName", "1a"))
  assert_false(valid("NCName", "a:b"))
  assert_true(valid("NCName", "a-b.c_d"))
  assert_false(valid("Name", ""))
  assert_false(valid("QName", ":a"))
  assert_false(valid("QName", "a:"))
  assert_false(valid("QName", "a:b:c"))
}

///|
test "dateTime rejects incomplete and misspelled forms" {
  assert_false(valid("dateTime", "2026-01-01"))
  assert_false(valid("dateTime", "2026-01-01 00:00:00"))
  assert_false(valid("dateTime", "2026-01-01T00:00"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00x"))
  assert_false(valid("dateTime", "2026-01-01T00:00:00+"))
}

///|
test "partial types reject truncated separators" {
  assert_false(valid("gMonthDay", "--02"))
  assert_false(valid("gMonthDay", "--02-"))
  assert_false(valid("gDay", "---1"))
  assert_false(valid("gDay", "--01"))
  assert_false(valid("gMonth", "--12--"))
  assert_false(valid("gMonth", "-12--"))
  assert_false(valid("gYearMonth", "2026"))
  assert_false(valid("gYearMonth", "2026-1"))
  assert_false(valid("gYear", "2026-"))
}

///|
test "duration keeps its components in order and whole" {
  // Months and years are counted in whole units; only the seconds field takes
  // a fraction. Components also have a fixed order.
  assert_false(valid("duration", "P1M1Y"))
  assert_false(valid("duration", "PT1H2"))
  assert_false(valid("duration", "P1.5Y"))
  assert_true(valid("duration", "PT1.5S"))
}

///|
test "numeric types reject incomplete exponents and bare points" {
  assert_true(valid("decimal", "1."))
  assert_false(valid("decimal", "."))
  assert_false(valid("double", "."))
  assert_false(valid("double", "1e"))
  assert_false(valid("double", "1e+"))
  assert_false(valid("float", "e3"))
}
