// Binary datatypes: hexBinary and base64Binary.
//
// Both decode to octets; the canonical form is kept so that equality and the
// `length` facet (which counts octets, not characters) work on the value.

///|
fn code_at_x(s : String, i : Int) -> Int {
  if i < 0 || i >= s.length() {
    -1
  } else {
    s.code_unit_at(i).to_int()
  }
}

///|
fn is_hex_digit(c : Int) -> Bool {
  (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
}

///|
fn hex_value(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 65 && c <= 70 {
    c - 55
  } else {
    c - 87
  }
}

///|
/// Decodes `hexBinary` into the canonical lowercase form.
pub fn parse_hex_binary(s : String) -> Result[Octets, ValErr] {
  let n = s.length()
  if n % 2 != 0 {
    return Err(Lexical("hexBinary needs an even number of digits"))
  }
  let buf = StringBuilder()
  let mut i = 0
  while i < n {
    let c = code_at_x(s, i)
    if !is_hex_digit(c) {
      return Err(Lexical("hexBinary contains a non-hex character"))
    }
    let v = hex_value(c)
    buf.write_char(Int::unsafe_to_char(if v < 10 { 48 + v } else { 87 + v }))
    i = i + 1
  }
  let canonical = buf.to_string()
  Ok({ canonical, len_bytes: n / 2 })
}

///|
/// Standard base64 with padding.
fn base64_encode(raw : String) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let buf = StringBuilder()
  let n = raw.length()
  let mut i = 0
  while i < n {
    let b0 = code_at_x(raw, i) & 0xFF
    let b1 = if i + 1 < n { code_at_x(raw, i + 1) & 0xFF } else { 0 }
    let b2 = if i + 2 < n { code_at_x(raw, i + 2) & 0xFF } else { 0 }
    let remaining = n - i
    buf.write_char(Int::unsafe_to_char(code_at_x(alphabet, b0 >> 2)))
    buf.write_char(
      Int::unsafe_to_char(code_at_x(alphabet, ((b0 & 3) << 4) | (b1 >> 4))),
    )
    if remaining > 1 {
      buf.write_char(
        Int::unsafe_to_char(code_at_x(alphabet, ((b1 & 15) << 2) | (b2 >> 6))),
      )
    } else {
      buf.write_char('=')
    }
    if remaining > 2 {
      buf.write_char(Int::unsafe_to_char(code_at_x(alphabet, b2 & 63)))
    } else {
      buf.write_char('=')
    }
    i = i + 3
  }
  buf.to_string()
}

///|
/// Decodes `base64Binary`. Whitespace inside the value is ignored, and both
/// padded and unpadded forms are accepted.
pub fn parse_base64_binary(s : String) -> Result[Octets, ValErr] {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  let buf = StringBuilder()
  let n = s.length()
  let mut acc = 0
  let mut bits = 0
  let mut pads = 0
  let mut count = 0
  let mut i = 0
  while i < n {
    let c = code_at_x(s, i)
    i = i + 1
    if c == 32 || c == 9 || c == 10 || c == 13 {
      continue
    }
    if c == 61 {
      pads = pads + 1
      continue
    }
    if pads > 0 {
      return Err(Lexical("base64 padding must come last"))
    }
    let mut value = -1
    let mut k = 0
    while k < 64 {
      if code_at_x(alphabet, k) == c {
        value = k
        break
      }
      k = k + 1
    }
    if value < 0 {
      return Err(Lexical("base64 contains a character outside the alphabet"))
    }
    count = count + 1
    acc = (acc << 6) | value
    bits = bits + 6
    if bits >= 8 {
      bits = bits - 8
      buf.write_char(Int::unsafe_to_char((acc >> bits) & 0xFF))
      acc = acc & ((1 << bits) - 1)
    }
  }
  if pads > 2 {
    return Err(Lexical("base64 has too much padding"))
  }
  if (count + pads) % 4 != 0 {
    return Err(Lexical("base64 length is not a multiple of four"))
  }
  let raw = buf.to_string()
  Ok({ canonical: base64_encode(raw), len_bytes: raw.length() })
}
