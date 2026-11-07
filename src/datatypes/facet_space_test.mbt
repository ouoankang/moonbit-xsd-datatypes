// Facets as they behave in the value space.
//
// The facet tests next to the implementation cover the arithmetic. These cover
// the places where "compare the values" and "compare the strings" disagree:
// NaN, infinities, values that have no order at all, and facets asked to apply
// to a type they do not describe.

///|
fn passes(t : @datatypes.SimpleType, s : String) -> Bool {
  match @datatypes.check_value(t, s) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
test "NaN is in no enumeration and satisfies no bound" {
  // Part 2 §3.2.5: NaN is unordered with respect to everything, itself
  // included, so `enumeration value="NaN"` matches nothing.
  let en = @datatypes.make_atomic_with("double", {
    ..@datatypes.no_facets(),
    enumeration: [Flt(NotANumber)],
  })
  assert_false(passes(en, "NaN"))
  assert_false(passes(en, "1"))

  let bounded = @datatypes.make_atomic_with("double", {
    ..@datatypes.no_facets(),
    min_inclusive: Some(Flt(Finite(0.0))),
  })
  assert_false(passes(bounded, "NaN"))
  assert_true(passes(bounded, "0"))
  // +INF is ordered and above 0, so it passes a lower bound.
  assert_true(passes(bounded, "INF"))
  assert_false(passes(bounded, "-1"))
}

///|
test "infinities rank outside the finite values" {
  let capped = @datatypes.make_atomic_with("double", {
    ..@datatypes.no_facets(),
    max_inclusive: Some(Flt(Finite(0.0))),
  })
  assert_false(passes(capped, "INF"))
  assert_true(passes(capped, "-INF"))
  assert_true(passes(capped, "0"))
  assert_true(passes(capped, "-0"))
  assert_false(passes(capped, "1e-300"))
}

///|
test "a timezoned value is not ordered against an unzoned one" {
  // Part 2 §3.2.7.3: an unzoned value denotes any instant in a 28-hour window,
  // so a bound that falls inside that window has no answer and the facet is
  // false. A bound outside the window does have one.
  let at = fn(s : String) -> @datatypes.XsdValue? {
    match @datatypes.validate_builtin("dateTime", s) {
      Ok(v) => Some(v)
      Err(_) => abort("expected a dateTime value")
    }
  }
  let bare = "2026-06-01T00:00:00"
  // 03:00Z sits inside [05-31T10:00Z, 06-01T14:00Z], the span `bare` can denote.
  let inside = @datatypes.make_atomic_with("dateTime", {
    ..@datatypes.no_facets(),
    min_inclusive: at("2026-06-01T03:00:00Z"),
  })
  assert_false(passes(inside, bare))
  // Before the window the order is certain: bare is later.
  let before = @datatypes.make_atomic_with("dateTime", {
    ..@datatypes.no_facets(),
    min_inclusive: at("2026-05-31T00:00:00Z"),
  })
  assert_true(passes(before, bare))
  // After it the order is certain the other way.
  let after = @datatypes.make_atomic_with("dateTime", {
    ..@datatypes.no_facets(),
    min_inclusive: at("2026-06-01T20:00:00Z"),
  })
  assert_false(passes(after, bare))
  // Two zoned values always compare.
  assert_true(
    passes(
      @datatypes.make_atomic_with("dateTime", {
        ..@datatypes.no_facets(),
        min_inclusive: at("2026-01-01T00:00:00Z"),
      }),
      "2026-06-01T00:00:00Z",
    ),
  )
}

///|
test "P1M and P30D are not ordered against each other" {
  // A month is not a fixed number of days: P1M is longer than P30D in a 31-day
  // month and shorter in February, so no single answer exists.
  let bound = match @datatypes.validate_builtin("duration", "P30D") {
    Ok(v) => v
    Err(_) => abort("expected a duration value")
  }
  let t = @datatypes.make_atomic_with("duration", {
    ..@datatypes.no_facets(),
    min_inclusive: Some(bound),
  })
  assert_false(passes(t, "P1M"))
  assert_true(passes(t, "P31D"))
  assert_false(passes(t, "P29D"))
}

///|
test "length does not apply to types that have none" {
  let t = @datatypes.make_atomic_with("decimal", {
    ..@datatypes.no_facets(),
    length: Some(3),
  })
  assert_false(passes(t, "1"))
  // QName and NOTATION are the exception: the facet is deprecated there and
  // never defines what a name's length would be, so it is skipped rather than
  // failed. See length_is_deprecated in facets.mbt.
  let q = @datatypes.make_atomic_with("QName", {
    ..@datatypes.no_facets(),
    length: Some(1),
  })
  assert_true(passes(q, "a-very-long-local-name"))
}

///|
test "totalDigits and fractionDigits refuse non-decimal values" {
  let td = @datatypes.make_atomic_with("string", {
    ..@datatypes.no_facets(),
    total_digits: Some(3),
  })
  assert_false(passes(td, "abc"))
  let fd = @datatypes.make_atomic_with("string", {
    ..@datatypes.no_facets(),
    fraction_digits: Some(1),
  })
  assert_false(passes(fd, "abc"))
}

///|
test "lexical_text renders each kind in its canonical form" {
  let text = fn(t : String, s : String) -> String {
    match @datatypes.validate_builtin(t, s) {
      Ok(v) => @datatypes.lexical_text(v)
      Err(e) => abort("expected \{t} to accept \{s}: \{e.to_string()}")
    }
  }
  assert_eq(text("decimal", "1.230"), "1.23")
  assert_eq(text("boolean", "1"), "true")
  assert_eq(text("boolean", "0"), "false")
  assert_eq(text("hexBinary", "0F"), "0f")
  assert_eq(text("base64Binary", "YQ=="), "YQ==")
  assert_eq(text("QName", "p:a"), "p:a")
  assert_eq(text("QName", "a"), "a")
  // zero padding is the writer's job, not the reader's
  assert_eq(text("date", "2026-01-05"), "2026-01-05")
  assert_eq(text("dateTime", "2026-01-05T01:02:03Z"), "2026-01-05T01:02:03Z")
  assert_eq(text("double", "INF"), "INF")
  assert_eq(text("double", "1.5"), "1.5")
}
