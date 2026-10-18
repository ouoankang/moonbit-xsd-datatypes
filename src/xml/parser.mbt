// Hand-written recursive-descent reader over UTF-16 code units.
//
// Indexing is in code units because MoonBit strings are UTF-16; every character
// this reader dispatches on is ASCII, and slicing only ever happens at ASCII
// delimiters, so surrogate pairs are never split.

///|
/// UTF-16 code unit values of the ASCII characters used in dispatch.
let cu_lt : Int = 60 // '<'
let cu_gt : Int = 62 // '>'
let cu_slash : Int = 47 // '/'
let cu_eq : Int = 61 // '='
let cu_quote : Int = 34 // '"'
let cu_apos : Int = 39 // '\''
let cu_bang : Int = 33 // '!'
let cu_question : Int = 63 // '?'
let cu_dash : Int = 45 // '-'
let cu_bracket_l : Int = 91 // '['
let cu_bracket_r : Int = 93 // ']'
let cu_amp : Int = 38 // '&'
let cu_semi : Int = 59 // ';'
let cu_hash : Int = 35 // '#'
let cu_colon : Int = 58 // ':'

///|
/// Reads one UTF-16 code unit as an Int, or -1 past the end.
fn cu_at(s : String, i : Int) -> Int {
  if i < 0 || i >= s.length() {
    -1
  } else {
    s.code_unit_at(i).to_int()
  }
}

///|
/// Mutable cursor plus the namespace scope stack.
///
/// The stack holds (prefix, uri) pairs. Pushing happens when an element
/// declares namespaces; popping truncates back to the length recorded on entry,
/// which is how inner declarations stop being visible to siblings.
priv struct Reader {
  src : String
  mut pos : Int
  scope : Array[(String, String)]
}

///|
fn Reader::new(src : String) -> Reader {
  let scope : Array[(String, String)] = [("xml", xml_namespace_uri)]
  { src, pos: 0, scope }
}

///|
fn Reader::len(self : Reader) -> Int {
  self.src.length()
}

///|
fn Reader::eof(self : Reader) -> Bool {
  self.pos >= self.len()
}

///|
fn Reader::peek(self : Reader) -> Int {
  if self.eof() {
    -1
  } else {
    cu_at(self.src, self.pos)
  }
}

///|
fn Reader::peek_at(self : Reader, offset : Int) -> Int {
  let i = self.pos + offset
  if i >= self.len() || i < 0 {
    -1
  } else {
    cu_at(self.src, i)
  }
}

///|
fn Reader::advance(self : Reader) -> Unit {
  self.pos = self.pos + 1
}

///|
fn Reader::skip_ws(self : Reader) -> Unit {
  while !(self.eof()) {
    let c = self.peek()
    if c == 32 || c == 9 || c == 10 || c == 13 {
      self.advance()
    } else {
      break
    }
  }
}

///|
fn is_name_start(c : Int) -> Bool {
  (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == cu_colon || c >= 0xC0
}

///|
fn is_name_char(c : Int) -> Bool {
  is_name_start(c) ||
  (c >= 48 && c <= 57) ||
  c == cu_dash ||
  c == 46 ||
  c == 0xB7
}

///|
fn Reader::read_name(self : Reader) -> String {
  let start = self.pos
  while !(self.eof()) && is_name_char(self.peek()) {
    self.advance()
  }
  self.src[start:self.pos].to_owned()
}

///|
/// Splits `prefix:local_name` into its two halves. A name with no colon has an empty
/// prefix. Only the first colon is significant; `a:b:c` is malformed but this
/// reader treats the remainder as the local_name name rather than failing, because
/// no XSD construct produces one.
fn split_qname(raw : String) -> (String, String) {
  let n = raw.length()
  let mut i = 0
  while i < n {
    if cu_at(raw, i) == cu_colon {
      return (raw[0:i].to_owned(), raw[i + 1:n].to_owned())
    }
    i = i + 1
  }
  ("", raw)
}

///|
/// Looks up the URI bound to `prefix` in the current scope. The last binding
/// wins, which is how nested redefinitions shadow outer ones.
fn Reader::resolve_prefix(self : Reader, prefix : String) -> String? {
  let mut i = self.scope.length() - 1
  while i >= 0 {
    let (p, uri) = self.scope[i]
    if p == prefix {
      return Some(uri)
    }
    i = i - 1
  }
  None
}

///|
/// Resolves a qualified name to a QName.
///
/// `is_attribute` matters: an unprefixed attribute is in *no* namespace, while
/// an unprefixed element takes the default namespace. Getting this backwards is
/// the single most common namespace bug, so it is an explicit parameter rather
/// than something the caller can forget.
fn Reader::make_qname(
  self : Reader,
  raw : String,
  is_attribute : Bool,
) -> Result[QName, XmlError] {
  let (prefix, local_name) = split_qname(raw)
  if prefix.is_empty() {
    if is_attribute {
      return Ok({ uri: "", local_name, prefix })
    }
    let dflt = match self.resolve_prefix("") {
      Some(uri) => uri
      None => ""
    }
    return Ok({ uri: dflt, local_name, prefix })
  }
  match self.resolve_prefix(prefix) {
    Some(uri) => Ok({ uri, local_name, prefix })
    None => Err(UnboundPrefix(prefix))
  }
}

///|
/// Decodes character and entity references in character data.
fn decode_refs(raw : String) -> Result[String, XmlError] {
  if !(raw.contains("&")) {
    return Ok(raw)
  }
  let out : Array[String] = []
  let n = raw.length()
  let mut i = 0
  let mut start = 0
  while i < n {
    if cu_at(raw, i) == cu_amp {
      if i > start {
        out.push(raw[start:i].to_owned())
      }
      let mut j = i + 1
      while j < n && cu_at(raw, j) != cu_semi {
        j = j + 1
      }
      if j >= n {
        return Err(BadCharRef(raw[i:n].to_owned()))
      }
      let body = raw[i + 1:j].to_owned()
      match decode_one_ref(body) {
        Ok(s) => out.push(s)
        Err(e) => return Err(e)
      }
      i = j + 1
      start = i
    } else {
      i = i + 1
    }
  }
  if start < n {
    out.push(raw[start:n].to_owned())
  }
  Ok(out.join(""))
}

///|
fn decode_one_ref(body : String) -> Result[String, XmlError] {
  if body.is_empty() {
    return Err(BadCharRef("&;"))
  }
  if cu_at(body, 0) == cu_hash {
    let mut hex = false
    let mut k = 1
    if body.length() > 1 {
      let c = cu_at(body, 1)
      if c == 120 || c == 88 {
        hex = true
        k = 2
      }
    }
    let digits = body[k:body.length()].to_owned()
    if digits.is_empty() {
      return Err(BadCharRef(body))
    }
    let mut value = 0
    let mut idx = 0
    while idx < digits.length() {
      let c = cu_at(digits, idx)
      let d = if c >= 48 && c <= 57 {
        c - 48
      } else if hex && c >= 97 && c <= 102 {
        c - 97 + 10
      } else if hex && c >= 65 && c <= 70 {
        c - 65 + 10
      } else {
        return Err(BadCharRef(body))
      }
      value = value * (if hex { 16 } else { 10 }) + d
      if value > 0x10FFFF {
        return Err(BadCharRef(body))
      }
      idx = idx + 1
    }
    if value == 0 {
      return Err(BadCharRef(body))
    }
    return Ok(code_point_to_string(value))
  }
  if body == "lt" {
    return Ok("<")
  }
  if body == "gt" {
    return Ok(">")
  }
  if body == "amp" {
    return Ok("&")
  }
  if body == "quot" {
    return Ok("\"")
  }
  if body == "apos" {
    return Ok("'")
  }
  Err(UnknownEntity(body))
}

///|
/// Encodes a code point as UTF-16 text, splitting astral code points into a
/// surrogate pair.
fn code_point_to_string(cp : Int) -> String {
  if cp <= 0xFFFF {
    return Int::unsafe_to_char(cp).to_string()
  }
  let v = cp - 0x10000
  let hi = 0xD800 + (v >> 10)
  let lo = 0xDC00 + (v & 0x3FF)
  let buf = StringBuilder()
  buf.write_char(Int::unsafe_to_char(hi))
  buf.write_char(Int::unsafe_to_char(lo))
  buf.to_string()
}

///|
/// Skips whitespace, comments, and processing instructions between markup.
fn Reader::skip_misc(self : Reader) -> Result[Unit, XmlError] {
  while true {
    self.skip_ws()
    if self.eof() || self.peek() != cu_lt {
      return Ok(())
    }
    if self.peek_at(1) == cu_bang {
      // comment or DOCTYPE
      if self.peek_at(2) == cu_dash && self.peek_at(3) == cu_dash {
        match self.skip_comment() {
          Ok(_) => continue
          Err(e) => return Err(e)
        }
      } else {
        return Err(Unsupported("DOCTYPE declarations are not supported"))
      }
    } else if self.peek_at(1) == cu_question {
      match self.skip_pi() {
        Ok(_) => continue
        Err(e) => return Err(e)
      }
    } else {
      return Ok(())
    }
  }
  Ok(())
}

///|
fn Reader::skip_comment(self : Reader) -> Result[Unit, XmlError] {
  self.pos = self.pos + 4 // <!--
  while !(self.eof()) {
    if self.peek() == cu_dash && self.peek_at(1) == cu_dash && self.peek_at(2) == cu_gt {
      self.pos = self.pos + 3
      return Ok(())
    }
    self.advance()
  }
  Err(UnexpectedEof)
}

///|
fn Reader::skip_pi(self : Reader) -> Result[Unit, XmlError] {
  self.pos = self.pos + 2 // <?
  while !(self.eof()) {
    if self.peek() == cu_question && self.peek_at(1) == cu_gt {
      self.pos = self.pos + 2
      return Ok(())
    }
    self.advance()
  }
  Err(UnexpectedEof)
}

///|
/// Parses one element, including its namespace declarations and children.
fn Reader::parse_element(self : Reader) -> Result[XmlElement, XmlError] {
  if self.peek() != cu_lt {
    return Err(NotAnElement)
  }
  self.advance()
  let raw_name = self.read_name()
  if raw_name.is_empty() {
    return Err(NotAnElement)
  }
  let scope_mark = self.scope.length()
  let ns_decls : Array[(String, String)] = []
  let attrs : Array[XmlAttr] = []
  // Attributes, collecting xmlns declarations into scope as we go so that later
  // attributes in the same tag resolve against them.
  while true {
    self.skip_ws()
    let c = self.peek()
    if c == cu_slash || c == cu_gt || c == -1 {
      break
    }
    let attr_name = self.read_name()
    if attr_name.is_empty() {
      return Err(UnterminatedTag)
    }
    self.skip_ws()
    if self.peek() != cu_eq {
      return Err(UnterminatedTag)
    }
    self.advance()
    self.skip_ws()
    let q = self.peek()
    if q != cu_quote && q != cu_apos {
      return Err(UnterminatedTag)
    }
    self.advance()
    let vstart = self.pos
    while !(self.eof()) && self.peek() != q {
      self.advance()
    }
    if self.eof() {
      return Err(UnterminatedTag)
    }
    let raw_value = self.src[vstart:self.pos].to_owned()
    self.advance()
    let decoded = match decode_refs(raw_value) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if attr_name == "xmlns" {
      self.scope.push(("", decoded))
      ns_decls.push(("", decoded))
    } else if attr_name.has_prefix("xmlns:") {
      let p = attr_name[6:attr_name.length()].to_owned()
      self.scope.push((p, decoded))
      ns_decls.push((p, decoded))
    } else {
      let name = match self.make_qname(attr_name, true) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      attrs.push({ name, value: decoded })
    }
  }
  let name = match self.make_qname(raw_name, false) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  if self.peek() == cu_slash {
    self.advance()
    if self.peek() != cu_gt {
      return Err(UnterminatedTag)
    }
    self.advance()
    self.scope.resize(scope_mark, ("", ""))
    return Ok({ name, attributes: attrs, children: [], ns_decls })
  }
  if self.peek() != cu_gt {
    return Err(UnterminatedTag)
  }
  self.advance()
  let children = match self.parse_children(raw_name) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  self.scope.resize(scope_mark, ("", ""))
  Ok({ name, attributes: attrs, children, ns_decls })
}

///|
/// Parses everything up to and including the matching end tag.
fn Reader::parse_children(self : Reader, parent_raw : String) -> Result[Array[XmlNode], XmlError] {
  let out : Array[XmlNode] = []
  let mut text_start = self.pos
  while true {
    if self.eof() {
      return Err(UnexpectedEof)
    }
    if self.peek() == cu_lt {
      if self.pos > text_start {
        let raw = self.src[text_start:self.pos].to_owned()
        let decoded = match decode_refs(raw) {
          Ok(t) => t
          Err(e) => return Err(e)
        }
        out.push(Text(decoded))
      }
      if self.peek_at(1) == cu_slash {
        let end_name = match self.read_end_tag() {
          Ok(n) => n
          Err(e) => return Err(e)
        }
        if end_name != parent_raw {
          return Err(MismatchedTag(parent_raw, end_name))
        }
        return Ok(out)
      } else if self.peek_at(1) == cu_bang {
        if self.peek_at(2) == cu_dash && self.peek_at(3) == cu_dash {
          match self.skip_comment() {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        } else if self.peek_at(2) == cu_bracket_l {
          match self.read_cdata() {
            Ok(t) => out.push(Text(t))
            Err(e) => return Err(e)
          }
        } else {
          return Err(Unsupported("DOCTYPE declarations are not supported"))
        }
      } else if self.peek_at(1) == cu_question {
        match self.skip_pi() {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      } else {
        let child = match self.parse_element() {
          Ok(e) => e
          Err(e) => return Err(e)
        }
        out.push(Element(child))
      }
      text_start = self.pos
    } else {
      self.advance()
    }
  }
  Ok(out)
}

///|
fn Reader::read_end_tag(self : Reader) -> Result[String, XmlError] {
  self.pos = self.pos + 2 // </
  let name = self.read_name()
  self.skip_ws()
  if self.peek() != cu_gt {
    return Err(UnterminatedTag)
  }
  self.advance()
  Ok(name)
}

///|
fn Reader::read_cdata(self : Reader) -> Result[String, XmlError] {
  self.pos = self.pos + 9 // <![CDATA[
  let start = self.pos
  while !(self.eof()) {
    if self.peek() == cu_bracket_r &&
      self.peek_at(1) == cu_bracket_r &&
      self.peek_at(2) == cu_gt {
      let t = self.src[start:self.pos].to_owned()
      self.pos = self.pos + 3
      return Ok(t)
    }
    self.advance()
  }
  Err(UnexpectedEof)
}

///|
/// Reads a whole document: an optional prolog, exactly one root element, and
/// optional trailing misc.
pub fn parse_xml(src : String) -> Result[XmlElement, XmlError] {
  let r = Reader::new(src)
  match r.skip_misc() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if r.eof() {
    return Err(UnexpectedEof)
  }
  let root = match r.parse_element() {
    Ok(e) => e
    Err(e) => return Err(e)
  }
  match r.skip_misc() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if !(r.eof()) {
    if r.peek() == cu_lt {
      return Err(MultipleRoots)
    }
    return Err(TextOutsideRoot)
  }
  Ok(root)
}

///|
/// Finds the first descendant element whose expanded name matches. A tiny
/// convenience used by the conformance driver and the CLI.
pub fn find_first(el : XmlElement, uri : String, local_name : String) -> XmlElement? {
  if el.name.uri == uri && el.name.local_name == local_name {
    return Some(el)
  }
  for node in el.children {
    match node {
      Element(child) =>
        match find_first(child, uri, local_name) {
          Some(found) => return Some(found)
          None => ()
        }
      Text(_) => ()
    }
  }
  None
}

///|
/// All direct child elements with the given expanded name.
pub fn child_elements(el : XmlElement, uri : String, local_name : String) -> Array[XmlElement] {
  let out : Array[XmlElement] = []
  for node in el.children {
    match node {
      Element(child) =>
        if child.name.uri == uri && child.name.local_name == local_name {
          out.push(child)
        }
      Text(_) => ()
    }
  }
  out
}

///|
/// Attribute value by expanded name.
pub fn attr_value(el : XmlElement, uri : String, local_name : String) -> String? {
  for a in el.attributes {
    if a.name.uri == uri && a.name.local_name == local_name {
      return Some(a.value)
    }
  }
  None
}
