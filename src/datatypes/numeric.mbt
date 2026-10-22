// Numeric datatypes beyond decimal: float, double, and the integer subtypes
// with their value-space ranges.

///|
/// Builds a decimal from a literal known to be valid.
fn dec_lit(s : String) -> Decimal {
  match parse_decimal(s) {
    Ok(d) => d
    Err(_) => abort("internal: bad decimal literal")
  }
}

///|
///|
/// 10^n for the range a float can hold. Values outside it saturate, which is
/// what the caller wants: an exponent past 308 is infinity, past -324 is zero.
fn pow10_double(n : Int) -> Double {
  if n > 400 {
    return 1.0e400
  }
  let mut r = 1.0
  let mut k = 0
  while k < n {
    r = r * 10.0
    k = k + 1
  }
  r
}

///|
/// Converts a validated float literal to the nearest binary64 value.
///
/// The literal has already been checked for shape, so this only has to get the
/// arithmetic right. Digits are accumulated into a 64-bit mantissa and scaled
/// once at the end; doing the scaling per digit would round at every step.
pub fn decimal_to_double(s : String) -> Double {
  let n = s.length()
  let mut i = 0
  let mut negative = false
  if i < n {
    let c = code_at_b(s, i)
    if c == 45 {
      negative = true
      i = i + 1
    } else if c == 43 {
      i = i + 1
    }
  }
  // Collect digits, remembering where the point sat relative to them.
  let digits = StringBuilder()
  let mut point_at = 0
  let mut seen_point = false
  while i < n {
    let c = code_at_b(s, i)
    if c >= 48 && c <= 57 {
      digits.write_char(Int::unsafe_to_char(c))
      if !seen_point {
        point_at = point_at + 1
      }
      i = i + 1
    } else if c == 46 && !seen_point {
      seen_point = true
      i = i + 1
    } else {
      break
    }
  }
  let mut exp10 = 0
  if i < n {
    i = i + 1
    let mut esign = 1
    if i < n && code_at_b(s, i) == 45 {
      esign = -1
      i = i + 1
    } else if i < n && code_at_b(s, i) == 43 {
      i = i + 1
    }
    let mut e = 0
    while i < n && code_at_b(s, i) >= 48 && code_at_b(s, i) <= 57 {
      // Cap the exponent: anything past a few hundred saturates anyway, and
      // letting it grow would overflow the accumulator below.
      if e < 100000 {
        e = e * 10 + (code_at_b(s, i) - 48)
      }
      i = i + 1
    }
    exp10 = e * esign
  }
  let ds = digits.to_string()
  // Strip leading zeros so the digit count reflects significant digits.
  let mut first = 0
  while first < ds.length() && code_at_b(ds, first) == 48 {
    first = first + 1
  }
  if first == ds.length() {
    return if negative { -0.0 } else { 0.0 }
  }
  let sig = ds[first:ds.length()].to_owned()
  // The exponent is measured against the digits actually kept: dropping the
  // tail would otherwise shift the value by a power of ten.
  let kept_n = if sig.length() > 17 { 17 } else { sig.length() }
  let mut e = exp10 + (point_at - first) - kept_n
  // A binary64 carries 17 significant decimal digits. Keep 17 and ROUND on the
  // 18th; truncating instead would turn
  // 0.1000000000000000055511151231257827 into a different number than 0.1,
  // which is exactly the failure this whole change is meant to fix.
  // Int is 32-bit here, so the accumulator has to be Int64: 17 decimal digits
  // do not fit in 2^31.
  let mut mant : Int64 = 0
  let mut k = 0
  while k < kept_n {
    mant = mant * 10L + (code_at_b(sig, k) - 48).to_int64()
    k = k + 1
  }
  if kept_n < sig.length() && code_at_b(sig, kept_n) >= 53 {
    mant = mant + 1L
    // Carrying out of the 17th digit (999...) costs a digit.
    if mant >= 100000000000000000L {
      mant = mant / 10L
      e = e + 1
    }
  }
  let mut v = mant.to_double()
  if e > 0 {
    v = v * pow10_double(e)
  } else if e < 0 {
    v = v / pow10_double(-e)
  }
  if negative {
    -v
  } else {
    v
  }
}

/// Parses `float` (bits = 32) or `double` (bits = 64).
///
/// `INF`, `+INF`, `-INF` and `NaN` are the only non-numeric forms, and they are
/// case-sensitive. Finite values keep their digits in a `Decimal` so that
/// enumeration and ordering see the value the document actually wrote.
fn parse_float_value(s : String, bits : Int) -> Result[FloatValue, ValErr] {
  if s == "NaN" {
    return Ok(NotANumber)
  }
  if s == "INF" || s == "+INF" {
    return Ok(PosInf)
  }
  if s == "-INF" {
    return Ok(NegInf)
  }
  let n = s.length()
  let mut i = 0
  let c0 = code_at_b(s, 0)
  // A sign is part of the lexical form; the value comes from the parser below.
  if c0 == 43 || c0 == 45 {
    i = 1
  }
  let int_start = i
  while i < n && is_digit_b(code_at_b(s, i)) {
    i = i + 1
  }
  let int_part = s[int_start:i].to_owned()
  let mut frac_part = ""
  if i < n && code_at_b(s, i) == 46 {
    i = i + 1
    let fs = i
    while i < n && is_digit_b(code_at_b(s, i)) {
      i = i + 1
    }
    frac_part = s[fs:i].to_owned()
  }
  if int_part.is_empty() && frac_part.is_empty() {
    return Err(Lexical("number has no digits"))
  }
  if i < n {
    let c = code_at_b(s, i)
    if c != 101 && c != 69 {
      return Err(Lexical("unexpected character in float"))
    }
    i = i + 1
    let sc = code_at_b(s, i)
    if sc == 43 || sc == 45 {
      i = i + 1
    }
    let es = i
    while i < n && is_digit_b(code_at_b(s, i)) {
      i = i + 1
    }
    if i == es {
      return Err(Lexical("exponent has no digits"))
    }
  }
  if i != n {
    return Err(Lexical("trailing characters in float"))
  }
  // The shape is valid; let the correctly-rounded parser produce the value.
  // A literal beyond the type's range becomes infinity here, which is what the
  // XSD value space says happens, and a literal below the smallest subnormal
  // becomes zero.
  let parsed = decimal_to_double(s)
  // xs:float is binary32. Rounding through Float is not cosmetic: 0.1 as a
  // float and 0.1 as a double are different values, and the facet comparisons
  // have to see the one the type actually denotes.
  let value = if bits == 32 { Float::from_double(parsed).to_double() } else { parsed }
  Ok(Finite(value))
}

///|
/// Range check for the integer subtypes.
fn check_integer_range(d : Decimal, type_name : String) -> Result[Unit, ValErr] {
  let bounds = match type_name {
    "long" => ("-9223372036854775808", "9223372036854775807")
    "int" => ("-2147483648", "2147483647")
    "short" => ("-32768", "32767")
    "byte" => ("-128", "127")
    "unsignedLong" => ("0", "18446744073709551615")
    "unsignedInt" => ("0", "4294967295")
    "unsignedShort" => ("0", "65535")
    "unsignedByte" => ("0", "255")
    "nonNegativeInteger" => ("0", "9")
    "positiveInteger" => ("1", "9")
    "nonPositiveInteger" => ("-9", "0")
    "negativeInteger" => ("-9", "-1")
    _ => ("", "")
  }
  let (lo, hi) = bounds
  if lo.is_empty() {
    return Ok(())
  }
  // For the four unbounded-in-practice types the bound is a single digit used
  // as a sign probe; compare against zero / one instead of a huge literal.
  match type_name {
    "nonNegativeInteger" =>
      if compare_decimal(d, decimal_zero()) < 0 {
        return Err(Lexical("nonNegativeInteger must not be negative"))
      }
    "positiveInteger" =>
      if compare_decimal(d, decimal_zero()) <= 0 {
        return Err(Lexical("positiveInteger must be positive"))
      }
    "nonPositiveInteger" =>
      if compare_decimal(d, decimal_zero()) > 0 {
        return Err(Lexical("nonPositiveInteger must not be positive"))
      }
    "negativeInteger" =>
      if compare_decimal(d, decimal_zero()) >= 0 {
        return Err(Lexical("negativeInteger must be negative"))
      }
    _ => {
      let low = dec_lit(lo)
      let high = dec_lit(hi)
      if compare_decimal(d, low) < 0 {
        return Err(Lexical("\{type_name} is below its minimum"))
      }
      if compare_decimal(d, high) > 0 {
        return Err(Lexical("\{type_name} is above its maximum"))
      }
    }
  }
  Ok(())
}
