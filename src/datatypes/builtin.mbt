// The entry point that turns a type name plus a lexical form into a value.
//
// Whitespace handling comes first because it changes the string every later
// step sees: `xs:string` preserves it, `xs:normalizedString` replaces it, and
// every other type collapses it.

///|
/// Parses a QName-shaped lexical form into prefix and local name.
fn parse_qname_value(s : String) -> Result[QNameValue, ValErr] {
  if s.is_empty() {
    return Err(Lexical("empty QName"))
  }
  let mut colon = -1
  let mut i = 0
  while i < s.length() {
    if code_at_b(s, i) == 58 {
      if colon >= 0 {
        return Err(Lexical("QName has more than one colon"))
      }
      colon = i
    }
    i = i + 1
  }
  if colon < 0 {
    if !is_ncname(s) {
      return Err(Lexical("invalid local name in QName"))
    }
    let q : QNameValue = { prefix: "", local_name: s }
    return Ok(q)
  }
  let prefix = s[0:colon].to_owned()
  let local_name = s[colon + 1:s.length()].to_owned()
  if !is_ncname(prefix) {
    return Err(Lexical("invalid prefix in QName"))
  }
  if !is_ncname(local_name) {
    return Err(Lexical("invalid local name in QName"))
  }
  let q : QNameValue = { prefix, local_name }
  Ok(q)
}

///|
/// `xs:language`: `[a-zA-Z]{1,8}('-'[a-zA-Z0-9]{1,8})*`
fn is_language(s : String) -> Bool {
  let n = s.length()
  let mut i = 0
  let mut segments = 0
  while i < n {
    let start = i
    while i < n && code_at_b(s, i) != 45 {
      i = i + 1
    }
    let len = i - start
    if len < 1 || len > 8 {
      return false
    }
    let mut k = start
    while k < i {
      let c = code_at_b(s, k)
      if segments == 0 {
        if !is_ascii_letter(c) {
          return false
        }
      } else if !is_ascii_letter(c) && !is_digit_b(c) {
        return false
      }
      k = k + 1
    }
    segments = segments + 1
    if i < n {
      i = i + 1
      if i == n {
        return false
      }
    }
  }
  segments > 0
}

///|
/// List types: one or more space-separated tokens.
fn check_token_list(s : String, kind : String) -> Result[XsdValue, ValErr] {
  if s.is_empty() {
    return Err(Lexical("list type needs at least one item"))
  }
  let n = s.length()
  let mut i = 0
  while i < n {
    let start = i
    while i < n && code_at_b(s, i) != 32 {
      i = i + 1
    }
    let item = s[start:i].to_owned()
    if !is_nmtoken(item) {
      return Err(Lexical("list item is not a valid token"))
    }
    if kind != "NMTOKEN" && !is_ncname(item) {
      return Err(Lexical("list item is not an NCName"))
    }
    if i < n {
      i = i + 1
    }
  }
  Ok(Str(s))
}

///|
/// `xs:anyURI` is famously permissive. The only checks worth making are that
/// no space and no control character survived the collapse.
fn parse_any_uri(s : String) -> Result[XsdValue, ValErr] {
  let mut i = 0
  while i < s.length() {
    let c = code_at_b(s, i)
    if c == 32 {
      return Err(Lexical("anyURI may not contain spaces"))
    }
    if c < 32 || c == 127 {
      return Err(Lexical("anyURI may not contain control characters"))
    }
    i = i + 1
  }
  Ok(Uri(s))
}

///|
fn parse_temporal(s : String, type_name : String) -> Result[Temporal, ValErr] {
  match type_name {
    "dateTime" => parse_date_time(s)
    "date" => parse_date(s)
    "time" => parse_time(s)
    "gYearMonth" => parse_g_year_month(s)
    "gYear" => parse_g_year(s)
    "gMonthDay" => parse_g_month_day(s)
    "gDay" => parse_g_day(s)
    "gMonth" => parse_g_month(s)
    _ => Err(Lexical("unknown temporal type"))
  }
}

///|
fn temporal_value(s : String, type_name : String) -> ValResult {
  match parse_temporal(s, type_name) {
    Ok(t) => Ok(Temporal(t))
    Err(e) => Err(e)
  }
}

///|
fn bounded_integer(s : String, type_name : String) -> ValResult {
  match parse_integer(s) {
    Ok(d) =>
      match check_integer_range(d, type_name) {
        Ok(_) => Ok(Dec(d))
        Err(e) => Err(e)
      }
    Err(e) => Err(e)
  }
}

///|
/// Parses any of the 44 built-in simple types. `type_name` is the local name
/// without the `xs:` prefix.
pub fn parse_builtin(type_name : String, raw : String) -> ValResult {
  if type_name == "string" {
    return Ok(Str(raw))
  }
  let s = if type_name == "normalizedString" {
    ws_replace(raw)
  } else {
    ws_collapse(raw)
  }
  match type_name {
    "normalizedString" => Ok(Str(s))
    "token" => Ok(Str(s))
    "language" => {
      if is_language(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not a language tag"))
      }
    }
    "NMTOKEN" => {
      if is_nmtoken(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not an NMTOKEN"))
      }
    }
    "Name" => {
      if !s.is_empty() && is_name_start(code_at_b(s, 0)) {
        Ok(Str(s))
      } else {
        Err(Lexical("not a Name"))
      }
    }
    "NCName" => {
      if is_ncname(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not an NCName"))
      }
    }
    "ID" => {
      if is_ncname(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not an NCName"))
      }
    }
    "IDREF" => {
      if is_ncname(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not an NCName"))
      }
    }
    "ENTITY" => {
      if is_ncname(s) {
        Ok(Str(s))
      } else {
        Err(Lexical("not an NCName"))
      }
    }
    "NMTOKENS" => check_token_list(s, "NMTOKEN")
    "IDREFS" => check_token_list(s, "IDREF")
    "ENTITIES" => check_token_list(s, "ENTITY")
    "boolean" => {
      if s == "true" || s == "1" {
        Ok(Bool(true))
      } else if s == "false" || s == "0" {
        Ok(Bool(false))
      } else {
        Err(Lexical("boolean must be true, false, 1, or 0"))
      }
    }
    "decimal" => {
      match parse_decimal(s) {
        Ok(d) => Ok(Dec(d))
        Err(e) => Err(e)
      }
    }
    "integer" => {
      match parse_integer(s) {
        Ok(d) => Ok(Dec(d))
        Err(e) => Err(e)
      }
    }
    "long" => bounded_integer(s, "long")
    "int" => bounded_integer(s, "int")
    "short" => bounded_integer(s, "short")
    "byte" => bounded_integer(s, "byte")
    "unsignedLong" => bounded_integer(s, "unsignedLong")
    "unsignedInt" => bounded_integer(s, "unsignedInt")
    "unsignedShort" => bounded_integer(s, "unsignedShort")
    "unsignedByte" => bounded_integer(s, "unsignedByte")
    "nonNegativeInteger" => bounded_integer(s, "nonNegativeInteger")
    "positiveInteger" => bounded_integer(s, "positiveInteger")
    "nonPositiveInteger" => bounded_integer(s, "nonPositiveInteger")
    "negativeInteger" => bounded_integer(s, "negativeInteger")
    "float" => {
      match parse_float_value(s, 32) {
        Ok(f) => Ok(Flt(f))
        Err(e) => Err(e)
      }
    }
    "double" => {
      match parse_float_value(s, 64) {
        Ok(f) => Ok(Flt(f))
        Err(e) => Err(e)
      }
    }
    "hexBinary" => {
      match parse_hex_binary(s) {
        Ok(b) => Ok(Bin(b))
        Err(e) => Err(e)
      }
    }
    "base64Binary" => {
      match parse_base64_binary(s) {
        Ok(b) => Ok(Bin(b))
        Err(e) => Err(e)
      }
    }
    "anyURI" => parse_any_uri(s)
    "QName" => {
      match parse_qname_value(s) {
        Ok(q) => Ok(Qn(q))
        Err(e) => Err(e)
      }
    }
    "NOTATION" => {
      match parse_qname_value(s) {
        Ok(q) =>
          Ok(
            Not(
              if q.prefix.is_empty() {
                q.local_name
              } else {
                "\{q.prefix}:\{q.local_name}"
              },
            ),
          )
        Err(e) => Err(e)
      }
    }
    "duration" => {
      match parse_duration(s) {
        Ok(d) => Ok(Dur(d))
        Err(e) => Err(e)
      }
    }
    "dateTime" => temporal_value(s, "dateTime")
    "date" => temporal_value(s, "date")
    "time" => temporal_value(s, "time")
    "gYearMonth" => temporal_value(s, "gYearMonth")
    "gYear" => temporal_value(s, "gYear")
    "gMonthDay" => temporal_value(s, "gMonthDay")
    "gDay" => temporal_value(s, "gDay")
    "gMonth" => temporal_value(s, "gMonth")
    _ => Err(Lexical("unknown built-in type: \{type_name}"))
  }
}
