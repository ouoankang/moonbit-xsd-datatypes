// Character and string helpers shared by every other file in this package.
//
// These sit at the bottom of the stack on purpose. The temporal parser, the
// regular expression engine and the facet checks all need to look at code
// units, normalise whitespace, and count code points; keeping them here means
// no file depends on one that happens to be compiled later.

///|
fn code_at_b(s : String, i : Int) -> Int {
  if i < 0 || i >= s.length() {
    -1
  } else {
    s.code_unit_at(i).to_int()
  }
}

///|
fn is_digit_b(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_ascii_letter(c : Int) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
}

///|
/// XML `NameStartChar`. Note that `:` is included: it is a legal character in
/// `xs:NMTOKEN` and `xs:Name`. `xs:NCName` is the one that excludes it, and that
/// exclusion is applied in `is_ncname`, not here.
fn is_name_start(c : Int) -> Bool {
  is_ascii_letter(c) || c == 95 || c == 58 || c >= 0xC0
}

///|
fn is_name_char(c : Int) -> Bool {
  is_name_start(c) || is_digit_b(c) || c == 45 || c == 46 || c == 0xB7
}

///|
/// `xs:normalizedString` semantics: tab, newline, and carriage return become a
/// space, nothing else changes.
pub fn ws_replace(s : String) -> String {
  let buf = StringBuilder()
  let mut i = 0
  while i < s.length() {
    let c = code_at_b(s, i)
    if c == 9 || c == 10 || c == 13 {
      buf.write_char(' ')
    } else {
      buf.write_char(Int::unsafe_to_char(c))
    }
    i = i + 1
  }
  buf.to_string()
}

///|
/// `xs:token` semantics: replace first, then collapse runs of spaces and trim.
pub fn ws_collapse(s : String) -> String {
  let replaced = ws_replace(s)
  let buf = StringBuilder()
  let mut i = 0
  let mut pending_space = false
  let mut wrote_any = false
  while i < replaced.length() {
    let c = code_at_b(replaced, i)
    if c == 32 {
      if wrote_any {
        pending_space = true
      }
    } else {
      if pending_space {
        buf.write_char(' ')
        pending_space = false
      }
      buf.write_char(Int::unsafe_to_char(c))
      wrote_any = true
    }
    i = i + 1
  }
  buf.to_string()
}

///|
fn is_ncname(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  let first = code_at_b(s, 0)
  if !is_name_start(first) || first == 58 {
    return false
  }
  let mut i = 1
  while i < s.length() {
    let c = code_at_b(s, i)
    if !is_name_char(c) || c == 58 {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn is_nmtoken(s : String) -> Bool {
  if s.is_empty() {
    return false
  }
  let mut i = 0
  while i < s.length() {
    if !is_name_char(code_at_b(s, i)) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Parses an unsigned decimal integer, or None when the digits do not fit in
/// an Int.
fn parse_uint(s : String) -> Int? {
  if s.is_empty() {
    return None
  }
  let mut v = 0
  let mut i = 0
  while i < s.length() {
    let c = code_at_b(s, i)
    if !is_digit_b(c) {
      return None
    }
    v = v * 10 + (c - 48)
    if v < 0 {
      return None
    }
    i = i + 1
  }
  Some(v)
}

///|
/// Number of Unicode code points, so that an astral character counts as one.
fn count_code_points(s : String) -> Int {
  let mut n = 0
  let mut i = 0
  while i < s.length() {
    let c = code_at_b(s, i)
    if c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length() {
      i = i + 2
    } else {
      i = i + 1
    }
    n = n + 1
  }
  n
}
