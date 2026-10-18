// Arbitrary-precision decimal, the backbone of XSD's numeric types.
//
// `xs:decimal` has no exponent and no bound on digits, so this keeps the digits
// as text. Parsing and normalization happen once; comparison walks the two
// normalized forms without converting to a fixed-width float.

///|
/// Reads one UTF-16 code unit as an Int, or -1 past the end.
fn code_at(s : String, i : Int) -> Int {
  if i < 0 || i >= s.length() {
    -1
  } else {
    s.code_unit_at(i).to_int()
  }
}

///|
fn is_digit(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
/// Strips leading zeros, keeping at least one digit.
fn strip_leading_zeros(s : String) -> String {
  let n = s.length()
  let mut i = 0
  while i < n - 1 && code_at(s, i) == 48 {
    i = i + 1
  }
  s[i:n].to_owned()
}

///|
/// Strips trailing zeros; may return the empty string.
fn strip_trailing_zeros(s : String) -> String {
  let mut n = s.length()
  while n > 0 && code_at(s, n - 1) == 48 {
    n = n - 1
  }
  s[0:n].to_owned()
}

///|
/// Builds a normalized decimal. Zero is never negative.
pub fn decimal_of(
  negative : Bool,
  int_part : String,
  frac_part : String,
) -> Decimal {
  let i = strip_leading_zeros(if int_part.is_empty() { "0" } else { int_part })
  let f = strip_trailing_zeros(frac_part)
  let is_zero = i == "0" && f.is_empty()
  { negative: negative && !is_zero, int_part: i, frac_part: f }
}

///|
/// A decimal zero.
pub fn decimal_zero() -> Decimal {
  { negative: false, int_part: "0", frac_part: "" }
}

///|
/// Parses the XSD `decimal` lexical space:
///
///     ('+' | '-')? ( [0-9]+ ('.' [0-9]*)? | '.' [0-9]+ )
///
/// Note what is *not* here: no exponent, no `Infinity`, no hex. Those belong to
/// `float` and `double` only, and accepting them here is a common bug.
pub fn parse_decimal(s : String) -> Result[Decimal, ValErr] {
  if s.is_empty() {
    return Err(Lexical("empty decimal"))
  }
  let n = s.length()
  let mut i = 0
  let mut negative = false
  let c0 = code_at(s, i)
  if c0 == 43 || c0 == 45 {
    negative = c0 == 45
    i = i + 1
  }
  let int_start = i
  while i < n && is_digit(code_at(s, i)) {
    i = i + 1
  }
  let int_part = s[int_start:i].to_owned()
  let mut frac_part = ""
  if i < n && code_at(s, i) == 46 {
    i = i + 1
    let frac_start = i
    while i < n && is_digit(code_at(s, i)) {
      i = i + 1
    }
    frac_part = s[frac_start:i].to_owned()
  }
  if i != n {
    return Err(Lexical("unexpected character in decimal: \{s[i:n].to_owned()}"))
  }
  if int_part.is_empty() && frac_part.is_empty() {
    return Err(Lexical("decimal has no digits"))
  }
  Ok(decimal_of(negative, int_part, frac_part))
}

///|
/// Parses the XSD `integer` lexical space: an optional sign followed by one or
/// more digits. `1.0` and `1e3` are rejected, which is exactly what separates
/// `integer` from `decimal`.
pub fn parse_integer(s : String) -> Result[Decimal, ValErr] {
  if s.is_empty() {
    return Err(Lexical("empty integer"))
  }
  let n = s.length()
  let mut i = 0
  let mut negative = false
  let c0 = code_at(s, i)
  if c0 == 43 || c0 == 45 {
    negative = c0 == 45
    i = i + 1
  }
  let start = i
  while i < n && is_digit(code_at(s, i)) {
    i = i + 1
  }
  if i != n || i == start {
    return Err(Lexical("not an integer: \{s}"))
  }
  Ok(decimal_of(negative, s[start:i].to_owned(), ""))
}

///|
/// True when the decimal carries no fractional digits.
pub fn is_integral(d : Decimal) -> Bool {
  d.frac_part.is_empty()
}

///|
/// Ordering on the value space. Returns -1, 0, or 1.
pub fn compare_decimal(a : Decimal, b : Decimal) -> Int {
  if a.negative != b.negative {
    return if a.negative { -1 } else { 1 }
  }
  let magnitude = compare_magnitude(a, b)
  if a.negative {
    -magnitude
  } else {
    magnitude
  }
}

///|
/// Compares absolute values: integer part by length then digit, then the
/// fractional part digit by digit with implicit trailing zeros.
fn compare_magnitude(a : Decimal, b : Decimal) -> Int {
  let il = a.int_part.length()
  let jl = b.int_part.length()
  if il != jl {
    return if il < jl { -1 } else { 1 }
  }
  let mut i = 0
  while i < il {
    let ca = code_at(a.int_part, i)
    let cb = code_at(b.int_part, i)
    if ca != cb {
      return if ca < cb { -1 } else { 1 }
    }
    i = i + 1
  }
  let fl = a.frac_part.length()
  let gl = b.frac_part.length()
  let max = if fl > gl { fl } else { gl }
  let mut k = 0
  while k < max {
    let ca = if k < fl { code_at(a.frac_part, k) } else { 48 }
    let cb = if k < gl { code_at(b.frac_part, k) } else { 48 }
    if ca != cb {
      return if ca < cb { -1 } else { 1 }
    }
    k = k + 1
  }
  0
}

///|
/// Total digits in the normalized form. Leading and trailing zeros are already
/// gone, so this is exactly the number of significant digits, which is what the
/// `totalDigits` facet is defined against.
pub fn total_digits(d : Decimal) -> Int {
  d.int_part.length() + d.frac_part.length()
}

///|
/// Number of fractional digits in the normalized form.
pub fn fraction_digits(d : Decimal) -> Int {
  d.frac_part.length()
}

///|
/// Renders the value in the canonical lexical form.
pub fn decimal_to_string(d : Decimal) -> String {
  let body = if d.frac_part.is_empty() {
    d.int_part
  } else {
    "\{d.int_part}.\{d.frac_part}"
  }
  if d.negative {
    "-\{body}"
  } else {
    body
  }
}

///|
/// Number of magnitude bits, used to bound `float`/`double` conversions that
/// need to know how large an integer is.
pub fn integer_magnitude_bits(d : Decimal) -> Int {
  if d.int_part == "0" {
    0
  } else {
    d.int_part.length() * 4
  }
}
