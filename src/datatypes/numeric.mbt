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
  let mut negative = false
  let c0 = code_at_b(s, 0)
  if c0 == 43 || c0 == 45 {
    negative = c0 == 45
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
  let mut exponent = 0
  if i < n {
    let c = code_at_b(s, i)
    if c != 101 && c != 69 {
      return Err(Lexical("unexpected character in float"))
    }
    i = i + 1
    let mut exp_negative = false
    let sc = code_at_b(s, i)
    if sc == 43 || sc == 45 {
      exp_negative = sc == 45
      i = i + 1
    }
    let es = i
    while i < n && is_digit_b(code_at_b(s, i)) {
      i = i + 1
    }
    if i == es {
      return Err(Lexical("exponent has no digits"))
    }
    let digits = s[es:i].to_owned()
    let parsed = match parse_uint(digits) {
      Some(v) => v
      None => 999999
    }
    exponent = if exp_negative { -parsed } else { parsed }
  }
  if i != n {
    return Err(Lexical("trailing characters in float"))
  }
  let all_digits = "\{int_part}\{frac_part}"
  let point = int_part.length() + exponent
  let limit = if bits == 32 { 39 } else { 309 }
  if point > limit {
    return Ok(if negative { NegInf } else { PosInf })
  }
  if point < -limit {
    return Ok(Finite(decimal_zero()))
  }
  let digits_len = all_digits.length()
  let mut new_int = ""
  let mut new_frac = ""
  if point <= 0 {
    let pad = StringBuilder()
    let mut k = 0
    while k < -point {
      pad.write_char('0')
      k = k + 1
    }
    new_int = "0"
    new_frac = "\{pad.to_string()}\{all_digits}"
  } else if point >= digits_len {
    let pad = StringBuilder()
    let mut k = digits_len
    while k < point {
      pad.write_char('0')
      k = k + 1
    }
    new_int = "\{all_digits}\{pad.to_string()}"
    new_frac = ""
  } else {
    new_int = all_digits[0:point].to_owned()
    new_frac = all_digits[point:digits_len].to_owned()
  }
  Ok(Finite(decimal_of(negative, new_int, new_frac)))
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
