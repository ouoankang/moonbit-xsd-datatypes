// The twelve facets, applied to a value in the value space.
//
// A facet is a constraint layered on top of a built-in type. `restriction`
// narrows by adding facets; `list` and `union` combine values. Everything here
// works on parsed values, never on raw strings, so `1.0` and `1` are the same
// decimal before any facet sees them.

///|
/// The facet set attached to a simple type. `None` means "not constrained".
pub(all) struct Facets {
  length : Int?
  min_length : Int?
  max_length : Int?
  /// Patterns grouped by the restriction step that declared them.
  ///
  /// Within a group they are OR-ed: any one matching satisfies that step.
  /// Across groups they are AND-ed, because each step adds a constraint rather
  /// than replacing the previous one. Flattening them into one list would lose
  /// the constraint from the base type.
  patterns : Array[Array[String]]
  enumeration : Array[XsdValue]
  max_inclusive : XsdValue?
  max_exclusive : XsdValue?
  min_inclusive : XsdValue?
  min_exclusive : XsdValue?
  total_digits : Int?
  fraction_digits : Int?
} derive(Debug)

///|
/// An empty facet set.
pub fn no_facets() -> Facets {
  {
    length: None,
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
}

///|
/// True for the two datatypes whose `length` facets are deprecated.
///
/// XSD 1.0 says: "The use of length, minLength and maxLength on datatypes
/// derived from QName is deprecated"; XSD 1.1 repeats it for QName, NOTATION and
/// their derivatives. Neither version defines what the length of a QName *is*,
/// because its value space is a triple, not a string. The conformance suite
/// reflects that: NIST marks a 16-character QName valid against length="1".
/// So the facet is skipped rather than guessed at.
fn length_is_deprecated(v : XsdValue) -> Bool {
  match v {
    Qn(_) | Not(_) => true
    _ => false
  }
}

///|
/// The quantity that `length` measures, or None when the type has no length.
fn measured_length(v : XsdValue) -> Int? {
  match v {
    Str(s) => Some(count_code_points(s))
    Bin(b) => Some(b.len_bytes)
    Uri(s) => Some(count_code_points(s))
    _ => None
  }
}

///|
/// Equality in the value space.
pub fn value_eq(a : XsdValue, b : XsdValue) -> Bool {
  match (a, b) {
    (Str(x), Str(y)) => x == y
    (Bool(x), Bool(y)) => x == y
    (Dec(x), Dec(y)) => compare_decimal(x, y) == 0
    (Flt(x), Flt(y)) =>
      match (x, y) {
        // IEEE equality: 0.0 and -0.0 are one value, and NaN equals nothing,
        // itself included. Both are what the XSD value space says.
        (Finite(dx), Finite(dy)) => dx == dy
        (PosInf, PosInf) => true
        (NegInf, NegInf) => true
        (NotANumber, NotANumber) => true
        _ => false
      }
    (Temporal(x), Temporal(y)) => x.kind == y.kind && compare_temporal(x, y) == 0
    (Dur(x), Dur(y)) =>
      x.negative == y.negative &&
      x.months == y.months &&
      compare_decimal(x.seconds, y.seconds) == 0
    (Bin(x), Bin(y)) => x.canonical == y.canonical
    (Uri(x), Uri(y)) => x == y
    (Qn(x), Qn(y)) => x.prefix == y.prefix && x.local_name == y.local_name
    (Not(x), Not(y)) => x == y
    _ => false
  }
}

///|
/// Ordering in the value space, or None when the type is not ordered.
///
/// `string`, `boolean`, `QName`, `NOTATION`, and `anyURI` have no order in XSD,
/// which is why `minInclusive` on them is a schema error rather than a runtime
/// one.
pub fn value_cmp(a : XsdValue, b : XsdValue) -> Int? {
  match (a, b) {
    (Dec(x), Dec(y)) => Some(compare_decimal(x, y))
    (Flt(x), Flt(y)) => Some(compare_floats(x, y))
    (Temporal(x), Temporal(y)) =>
      if x.kind == y.kind {
        Some(compare_temporal(x, y))
      } else {
        None
      }
    (Dur(x), Dur(y)) => Some(compare_durations(x, y))
    _ => None
  }
}

///|
/// Order on floats follows IEEE 754 total order enough for validation:
/// -INF < finite < +INF < NaN.
fn compare_floats(a : FloatValue, b : FloatValue) -> Int {
  let rank = fn(f : FloatValue) -> Int {
    match f {
      NegInf => 0
      Finite(_) => 1
      PosInf => 2
      NotANumber => 3
    }
  }
  let ra = rank(a)
  let rb = rank(b)
  if ra != rb {
    return if ra < rb { -1 } else { 1 }
  }
  match (a, b) {
    (Finite(x), Finite(y)) =>
      if x < y {
        -1
      } else if x > y {
        1
      } else {
        0
      }
    _ => 0
  }
}

///|
/// Order on durations: the month part first, then the second part. XSD does not
/// define a total order on durations, but this is the ordering a validator
/// needs to honour `minInclusive` when both ends are pure seconds or pure
/// months.
fn compare_durations(a : Duration, b : Duration) -> Int {
  let sign_a = if a.negative { -1 } else { 1 }
  let sign_b = if b.negative { -1 } else { 1 }
  if a.months != b.months {
    return if a.months * sign_a < b.months * sign_b { -1 } else { 1 }
  }
  let c = compare_decimal(a.seconds, b.seconds)
  if c == 0 {
    return 0
  }
  if a.negative {
    -c
  } else {
    c
  }
}

///|
/// True for the one value that is unordered with respect to everything,
/// including itself.
fn is_nan_value(v : XsdValue) -> Bool {
  match v {
    Flt(NotANumber) => true
    _ => false
  }
}

///|
/// Applies every facet present in `f` to `v`.
pub fn apply_facets(v : XsdValue, raw : String, f : Facets) -> Result[Unit, ValErr] {
  let measured = measured_length(v)
  let skip_length = length_is_deprecated(v)
  match f.length {
    Some(want) =>
      if skip_length {
        ()
      } else {
      match measured {
        Some(actual) =>
          if actual != want {
            return Err(Facet("length is \{actual}, expected \{want}"))
          }
        None => return Err(Facet("length does not apply to this type"))
      }
      }
    None => ()
  }
  match f.min_length {
    Some(want) =>
      if skip_length {
        ()
      } else {
      match measured {
        Some(actual) =>
          if actual < want {
            return Err(Facet("length \{actual} is below minLength \{want}"))
          }
        None => return Err(Facet("minLength does not apply to this type"))
      }
      }
    None => ()
  }
  match f.max_length {
    Some(want) =>
      if skip_length {
        ()
      } else {
      match measured {
        Some(actual) =>
          if actual > want {
            return Err(Facet("length \{actual} is above maxLength \{want}"))
          }
        None => return Err(Facet("maxLength does not apply to this type"))
      }
      }
    None => ()
  }
  if !f.patterns.is_empty() {
    // XSD defines `pattern` against the lexical representation, not against the
    // canonical form of the value. `1` and `true` are the same boolean, but a
    // pattern of `1` only matches the first spelling.
    let text = raw
    // Every restriction step must be satisfied; within a step any pattern will
    // do. XSD anchors each one at head and tail, so this is a full-string match.
    for group in f.patterns {
      let mut matched = false
      for p in group {
        if xsd_pattern_full_match(p, text) {
          matched = true
          break
        }
      }
      if !matched {
        return Err(Facet("value does not match any pattern"))
      }
    }
  }
  if !f.enumeration.is_empty() {
    let mut found = false
    for candidate in f.enumeration {
      if value_eq(v, candidate) {
        found = true
        break
      }
      // A union's enumeration is stored as parsed against `string`, because the
      // facets on a union have no single lexical space. Comparing the raw
      // lexical form against that string recovers the match without pretending
      // the two values have the same type.
      match candidate {
        Str(s) =>
          if s == raw {
            found = true
            break
          }
        _ => ()
      }
    }
    if !found {
      return Err(Facet("value is not in the enumeration"))
    }
  }
  // NaN is not ordered with respect to any value, itself included, so it cannot
  // satisfy an ordering facet. Without this, the rank used to make NaN sort
  // after +INF would let it pass a one-sided bound.
  let has_ordering_facet = f.min_inclusive is Some(_) ||
    f.max_inclusive is Some(_) ||
    f.min_exclusive is Some(_) ||
    f.max_exclusive is Some(_)
  if has_ordering_facet && is_nan_value(v) {
    return Err(Facet("NaN cannot satisfy an ordering facet"))
  }
  match f.min_inclusive {
    Some(bound) =>
      match value_cmp(v, bound) {
        Some(c) =>
          if c < 0 {
            return Err(Facet("value is below minInclusive"))
          }
        None => return Err(Facet("minInclusive needs an ordered type"))
      }
    None => ()
  }
  match f.max_inclusive {
    Some(bound) =>
      match value_cmp(v, bound) {
        Some(c) =>
          if c > 0 {
            return Err(Facet("value is above maxInclusive"))
          }
        None => return Err(Facet("maxInclusive needs an ordered type"))
      }
    None => ()
  }
  match f.min_exclusive {
    Some(bound) =>
      match value_cmp(v, bound) {
        Some(c) =>
          if c <= 0 {
            return Err(Facet("value is not above minExclusive"))
          }
        None => return Err(Facet("minExclusive needs an ordered type"))
      }
    None => ()
  }
  match f.max_exclusive {
    Some(bound) =>
      match value_cmp(v, bound) {
        Some(c) =>
          if c >= 0 {
            return Err(Facet("value is not below maxExclusive"))
          }
        None => return Err(Facet("maxExclusive needs an ordered type"))
      }
    None => ()
  }
  match f.total_digits {
    Some(want) =>
      match v {
        Dec(d) =>
          if total_digits(d) > want {
            return Err(Facet("totalDigits \{total_digits(d)} exceeds \{want}"))
          }
        _ => return Err(Facet("totalDigits applies to decimal types only"))
      }
    None => ()
  }
  match f.fraction_digits {
    Some(want) =>
      match v {
        Dec(d) =>
          if fraction_digits(d) > want {
            return Err(
              Facet("fractionDigits \{fraction_digits(d)} exceeds \{want}"),
            )
          }
        _ => return Err(Facet("fractionDigits applies to decimal types only"))
      }
    None => ()
  }
  Ok(())
}

///|
/// The string a `pattern` facet matches against: the canonical lexical form of
/// the value.
pub fn lexical_text(v : XsdValue) -> String {
  match v {
    Str(s) => s
    Bool(b) => if b { "true" } else { "false" }
    Dec(d) => decimal_to_string(d)
    Flt(f) =>
      match f {
        // Not the XSD canonical form (`1.0E0`); this is the shortest string
        // that round-trips, which is what a reader wants to see. Canonical
        // output would be a separate formatting concern.
        Finite(d) => d.to_string()
        PosInf => "INF"
        NegInf => "-INF"
        NotANumber => "NaN"
      }
    Bin(b) => b.canonical
    Uri(s) => s
    Qn(q) => if q.prefix.is_empty() { q.local_name } else { "\{q.prefix}:\{q.local_name}" }
    Not(s) => s
    Temporal(t) => temporal_text(t)
    Dur(d) => duration_text(d)
  }
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
fn year_text(t : Temporal) -> String {
  let y = t.year
  let mut s = if y < 1000 { "0\{y}" } else { "\{y}" }
  if y < 100 {
    s = "0\{s}"
  }
  if y < 10 {
    s = "0\{s}"
  }
  if t.year_negative {
    "-\{s}"
  } else {
    s
  }
}

///|
fn tz_text(t : Temporal) -> String {
  match t.tz {
    None => ""
    Some(m) => {
      if m == 0 {
        "Z"
      } else {
        let abs = if m < 0 { -m } else { m }
        let sign = if m < 0 { "-" } else { "+" }
        "\{sign}\{pad2(abs / 60)}:\{pad2(abs % 60)}"
      }
    }
  }
}

///|
fn temporal_text(t : Temporal) -> String {
  let frac = if t.frac_part.is_empty() { "" } else { ".\{t.frac_part}" }
  let date_part = "\{year_text(t)}-\{pad2(t.month)}-\{pad2(t.day)}"
  let time_part = "\{pad2(t.hour)}:\{pad2(t.minute)}:\{pad2(t.second)}\{frac}"
  let tz = tz_text(t)
  match t.kind {
    DateTime => "\{date_part}T\{time_part}\{tz}"
    Date => "\{date_part}\{tz}"
    Time => "\{time_part}\{tz}"
    GYearMonth => "\{year_text(t)}-\{pad2(t.month)}\{tz}"
    GYear => "\{year_text(t)}\{tz}"
    GMonthDay => "--\{pad2(t.month)}-\{pad2(t.day)}\{tz}"
    GDay => "---\{pad2(t.day)}\{tz}"
    GMonth => "--\{pad2(t.month)}\{tz}"
  }
}

///|
fn duration_text(d : Duration) -> String {
  let sign = if d.negative { "-" } else { "" }
  let years = d.months / 12
  let months = d.months % 12
  let buf = StringBuilder()
  if years != 0 {
    buf.write_string("\{years}Y")
  }
  if months != 0 {
    buf.write_string("\{months}M")
  }
  let total = decimal_to_string(d.seconds)
  if total != "0" {
    buf.write_string("T")
    buf.write_string("\{total}S")
  }
  let body = buf.to_string()
  if body.is_empty() {
    "P0D"
  } else {
    "\{sign}P\{body}"
  }
}
