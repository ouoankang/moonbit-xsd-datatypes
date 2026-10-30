// XML Schema's regular expression dialect, the one the `pattern` facet uses.
//
// It is NOT ECMA-262, and the differences matter:
//
//   * `pattern` is a *search*: the value is valid if the expression matches
//     somewhere inside it. There is no implicit anchoring, and `^` / `$` are
//     ordinary characters.
//   * No lookahead, no lookbehind, no backreferences.
//   * `\d` is the Unicode `Nd` category, not ASCII digits; `\w` and `\s` are
//     likewise Unicode-defined.
//   * `\i` and `\c` mean "XML name-start character" and "XML name character".
//   * Character class subtraction (`[a-z-[aeiou]]`) exists.
//
// Unicode category membership is approximated by the ranges below rather than
// the full UCD tables. That is a documented limitation, not an oversight: the
// conformance suite exercises the ASCII cases overwhelmingly.

///|
/// Decodes one code point starting at `i`, returning it with the next index.
/// Surrogate pairs are combined so that astral characters count as one.
fn cp_at(s : String, i : Int) -> (Int, Int) {
  let c = code_at_b(s, i)
  if c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length() {
    let lo = code_at_b(s, i + 1)
    if lo >= 0xDC00 && lo <= 0xDFFF {
      return (((c - 0xD800) << 10) + (lo - 0xDC00) + 0x10000, i + 2)
    }
  }
  (c, i + 1)
}

///|
/// A character class: a set of code point ranges plus a set of named
/// categories, optionally negated.
pub struct CharClass {
  negated : Bool
  ranges : Array[(Int, Int)]
  /// Category names such as "d", "w", "s", "i", "c", or the inside of `\p{...}`.
  categories : Array[String]
  /// Subtracted ranges, from `[a-z-[aeiou]]`.
  excluded : Array[(Int, Int)]
} derive(Debug)

pub extend CharClass with @debug.Debug::{to_repr}

///|
pub enum ReNode {
  Empty
  Char(Int)
  AnyChar
  Class(CharClass)
  Concat(Array[ReNode])
  Alt(Array[ReNode])
  Repeat(ReNode, Int, Int)
} derive(Debug)

pub extend ReNode with @debug.Debug::{to_repr}

///|
/// Bounds on repetition. `Repeat` uses -1 for "unbounded".
let repeat_unbounded : Int = -1

///|
/// Result type for the regex parser.
pub type ReResult = Result[ReNode, String]

///|
/// Cursor over the pattern source.
priv struct ReCursor {
  src : String
  mut pos : Int
}

///|
fn ReCursor::peek(self : ReCursor) -> Int {
  code_at_b(self.src, self.pos)
}

///|
fn ReCursor::eof(self : ReCursor) -> Bool {
  self.pos >= self.src.length()
}

///|
fn ReCursor::eat(self : ReCursor, c : Int) -> Bool {
  if self.peek() == c {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
/// Parses an XSD regular expression into an AST.
pub fn parse_xsd_regex(src : String) -> ReResult {
  let c : ReCursor = { src, pos: 0 }
  let node = match parse_alt(c) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err("unexpected character at offset \{c.pos}")
  }
  Ok(node)
}

///|
fn parse_alt(c : ReCursor) -> ReResult {
  let branches : Array[ReNode] = []
  let first = match parse_concat(c) {
    Ok(n) => n
    Err(e) => return Err(e)
  }
  branches.push(first)
  while c.eat(124) {
    let next = match parse_concat(c) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    branches.push(next)
  }
  if branches.length() == 1 {
    Ok(branches[0])
  } else {
    Ok(Alt(branches))
  }
}

///|
fn parse_concat(c : ReCursor) -> ReResult {
  let items : Array[ReNode] = []
  while !c.eof() && c.peek() != 124 && c.peek() != 41 {
    let atom = match parse_atom(c) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    let quantified = match parse_quantifier(c, atom) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    items.push(quantified)
  }
  if items.is_empty() {
    Ok(Empty)
  } else if items.length() == 1 {
    Ok(items[0])
  } else {
    Ok(Concat(items))
  }
}

///|
fn parse_quantifier(c : ReCursor, atom : ReNode) -> ReResult {
  if c.eat(63) {
    // '?'
    return Ok(Repeat(atom, 0, 1))
  }
  if c.eat(42) {
    // '*'
    return Ok(Repeat(atom, 0, repeat_unbounded))
  }
  if c.eat(43) {
    // '+'
    return Ok(Repeat(atom, 1, repeat_unbounded))
  }
  if c.peek() == 123 {
    // '{'
    c.pos = c.pos + 1
    let min = match read_uint(c) {
      Some(v) => v
      None => return Err("repetition needs a lower bound")
    }
    let mut max = min
    if c.eat(44) {
      if c.peek() == 125 {
        max = repeat_unbounded
      } else {
        max = match read_uint(c) {
          Some(v) => v
          None => return Err("repetition upper bound must be a number")
        }
      }
    }
    if !c.eat(125) {
      return Err("repetition must be closed with '}'")
    }
    if max != repeat_unbounded && max < min {
      return Err("repetition upper bound is below the lower bound")
    }
    return Ok(Repeat(atom, min, max))
  }
  Ok(atom)
}

///|
fn read_uint(c : ReCursor) -> Int? {
  let start = c.pos
  let mut value = 0
  while is_digit_b(c.peek()) {
    value = value * 10 + (c.peek() - 48)
    c.pos = c.pos + 1
  }
  if c.pos == start {
    None
  } else {
    Some(value)
  }
}

///|
fn parse_atom(c : ReCursor) -> ReResult {
  if c.eof() {
    return Err("unexpected end of pattern")
  }
  let ch = c.peek()
  if ch == 40 {
    // '('
    c.pos = c.pos + 1
    if c.eat(63) {
      // XSD has no `(?:`; a `?` right after `(` is illegal.
      return Err("'(?' is not valid in XSD regular expressions")
    }
    let inner = match parse_alt(c) {
      Ok(n) => n
      Err(e) => return Err(e)
    }
    if !c.eat(41) {
      return Err("unclosed group")
    }
    return Ok(inner)
  }
  if ch == 91 {
    // '['
    return parse_class(c)
  }
  if ch == 46 {
    c.pos = c.pos + 1
    return Ok(AnyChar)
  }
  if ch == 92 {
    // '\'
    c.pos = c.pos + 1
    return parse_escape(c)
  }
  if ch == 42 || ch == 43 || ch == 63 || ch == 123 || ch == 125 {
    return Err("quantifier without an atom")
  }
  if ch == 41 {
    return Err("unbalanced ')'")
  }
  let (cp, next) = cp_at(c.src, c.pos)
  c.pos = next
  Ok(Char(cp))
}

///|
/// Escapes outside a character class.
fn parse_escape(c : ReCursor) -> Result[ReNode, String] {
  if c.eof() {
    return Err("trailing backslash")
  }
  let ch = c.peek()
  // Single-character escapes for regex metacharacters.
  if ch == 110 {
    // 'n'
    c.pos = c.pos + 1
    return Ok(Char(10))
  }
  if ch == 114 {
    // 'r'
    c.pos = c.pos + 1
    return Ok(Char(13))
  }
  if ch == 116 {
    // 't'
    c.pos = c.pos + 1
    return Ok(Char(9))
  }
  if ch == 92 || ch == 124 || ch == 46 || ch == 45 || ch == 94 || ch == 63 ||
    ch == 42 || ch == 43 || ch == 123 || ch == 125 || ch == 40 || ch == 41 ||
    ch == 91 || ch == 93 {
    c.pos = c.pos + 1
    return Ok(Char(ch))
  }
  if ch == 100 || ch == 68 || ch == 119 || ch == 87 || ch == 115 || ch == 83 ||
    ch == 105 || ch == 73 || ch == 99 || ch == 67 {
    c.pos = c.pos + 1
    let name = match ch {
      100 => "d"
      68 => "D"
      119 => "w"
      87 => "W"
      115 => "s"
      83 => "S"
      105 => "i"
      73 => "I"
      99 => "c"
      67 => "C"
      _ => ""
    }
    return Ok(
      Class({
        negated: false,
        ranges: [],
        categories: [name],
        excluded: [],
      }),
    )
  }
  if ch == 112 || ch == 80 {
    // \p{...} / \P{...}
    c.pos = c.pos + 1
    if !c.eat(123) {
      return Err("\\p must be followed by {category}")
    }
    let start = c.pos
    while !c.eof() && c.peek() != 125 {
      c.pos = c.pos + 1
    }
    if c.eof() {
      return Err("unclosed \\p{...}")
    }
    let cat = c.src[start:c.pos].to_owned()
    c.pos = c.pos + 1
    return Ok(
      Class({
        negated: ch == 80,
        ranges: [],
        categories: [cat],
        excluded: [],
      }),
    )
  }
  return Err("unsupported escape \\\{Int::unsafe_to_char(ch)}")
}

///|
/// Parses `[...]`, including negation and subtraction.
fn parse_class(c : ReCursor) -> Result[ReNode, String] {
  if !c.eat(91) {
    return Err("expected '['")
  }
  let negated = c.eat(94)
  let ranges : Array[(Int, Int)] = []
  let categories : Array[String] = []
  let excluded : Array[(Int, Int)] = []
  let mut first = true
  while !c.eof() {
    // A ']' as the very first item is a literal.
    if c.peek() == 93 && !first {
      c.pos = c.pos + 1
      return Ok(
        Class({ negated, ranges, categories, excluded }),
      )
    }
    first = false
    // Subtraction: '-[' inside the class.
    if c.peek() == 45 && code_at_b(c.src, c.pos + 1) == 91 {
      c.pos = c.pos + 1
      let sub = match parse_class(c) {
        Ok(Class(inner)) => inner
        Ok(_) => return Err("subtraction needs a character class")
        Err(e) => return Err(e)
      }
      for r in sub.ranges {
        excluded.push(r)
      }
      continue
    }
    let (lo, null_or_cat) = match read_class_char(c) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if null_or_cat != "" {
      categories.push(null_or_cat)
      continue
    }
    // Range?
    if c.peek() == 45 && code_at_b(c.src, c.pos + 1) != 93 &&
      code_at_b(c.src, c.pos + 1) != 45 {
      c.pos = c.pos + 1
      let (hi, cat2) = match read_class_char(c) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if cat2 != "" {
        return Err("a category cannot be the end of a range")
      }
      ranges.push((lo, hi))
    } else {
      ranges.push((lo, lo))
    }
  }
  return Err("unclosed character class")
}

///|
/// Reads one item inside a character class. Returns (code point, "") for a
/// plain character, or (0, category) for an escape naming a category.
fn read_class_char(c : ReCursor) -> Result[(Int, String), String] {
  if c.eof() {
    return Err("unexpected end of character class")
  }
  let ch = c.peek()
  if ch == 92 {
    c.pos = c.pos + 1
    if c.eof() {
      return Err("trailing backslash in character class")
    }
    let e = c.peek()
    if e == 110 {
      c.pos = c.pos + 1
      return Ok((10, ""))
    }
    if e == 114 {
      c.pos = c.pos + 1
      return Ok((13, ""))
    }
    if e == 116 {
      c.pos = c.pos + 1
      return Ok((9, ""))
    }
    if e == 100 || e == 68 || e == 119 || e == 87 || e == 115 || e == 83 ||
      e == 105 || e == 73 || e == 99 || e == 67 {
      c.pos = c.pos + 1
      let name = match e {
        100 => "d"
        68 => "D"
        119 => "w"
        87 => "W"
        115 => "s"
        83 => "S"
        105 => "i"
        73 => "I"
        99 => "c"
        67 => "C"
        _ => ""
      }
      return Ok((0, name))
    }
    if e == 112 || e == 80 {
      c.pos = c.pos + 1
      if !c.eat(123) {
        return Err("\\p must be followed by {category}")
      }
      let start = c.pos
      while !c.eof() && c.peek() != 125 {
        c.pos = c.pos + 1
      }
      if c.eof() {
        return Err("unclosed \\p{...}")
      }
      let cat = c.src[start:c.pos].to_owned()
      c.pos = c.pos + 1
      return Ok((0, if e == 80 { "\{cat}^" } else { cat }))
    }
    c.pos = c.pos + 1
    return Ok((e, ""))
  }
  let (cp, next) = cp_at(c.src, c.pos)
  c.pos = next
  Ok((cp, ""))
}

///|
/// True when `cp` falls in one of the ranges.
fn in_ranges(cp : Int, ranges : Array[(Int, Int)]) -> Bool {
  for r in ranges {
    if cp >= r.0 && cp <= r.1 {
      return true
    }
  }
  false
}

///|
/// XML NameStartChar, approximated.
fn is_xml_name_start(cp : Int) -> Bool {
  cp == 58 || cp == 95 ||
  (cp >= 65 && cp <= 90) ||
  (cp >= 97 && cp <= 122) ||
  (cp >= 0xC0 && cp <= 0x2FF) ||
  (cp >= 0x370 && cp <= 0x1FFF) ||
  (cp >= 0x3001 && cp <= 0xD7FF)
}

///|
/// XML NameChar, approximated.
fn is_xml_name_char(cp : Int) -> Bool {
  is_xml_name_start(cp) ||
  cp == 45 ||
  cp == 46 ||
  (cp >= 48 && cp <= 57) ||
  cp == 0xB7 ||
  (cp >= 0x300 && cp <= 0x36F)
}

///|
/// Decimal digit in any script, approximated by the blocks that actually appear
/// in exchanged data.
fn is_unicode_digit(cp : Int) -> Bool {
  (cp >= 48 && cp <= 57) ||
  (cp >= 0x660 && cp <= 0x669) ||
  (cp >= 0x6F0 && cp <= 0x6F9) ||
  (cp >= 0x966 && cp <= 0x96F) ||
  (cp >= 0x9E6 && cp <= 0x9EF) ||
  (cp >= 0xFF10 && cp <= 0xFF19)
}

///|
fn is_unicode_space(cp : Int) -> Bool {
  cp == 32 || cp == 9 || cp == 10 || cp == 13 ||
  cp == 0xA0 || cp == 0x1680 ||
  (cp >= 0x2000 && cp <= 0x200A) ||
  cp == 0x2028 || cp == 0x2029 ||
  cp == 0x202F || cp == 0x205F || cp == 0x3000
}

///|
fn is_unicode_letter(cp : Int) -> Bool {
  (cp >= 65 && cp <= 90) ||
  (cp >= 97 && cp <= 122) || (cp >= 0xC0 && cp <= 0x24F) ||
  (cp >= 0x370 && cp <= 0x1FFF) || (cp >= 0x2C00 && cp <= 0xD7FF) ||
  (cp >= 0xF900 && cp <= 0xFDCF) || (cp >= 0x10000 && cp <= 0xEFFFF)
}

///|
/// Upper/lower case classification, ASCII plus Latin-1.
fn is_unicode_upper(cp : Int) -> Bool {
  (cp >= 65 && cp <= 90) || (cp >= 0xC0 && cp <= 0xDE && cp != 0xD7)
}

///|
fn is_unicode_lower(cp : Int) -> Bool {
  (cp >= 97 && cp <= 122) || (cp >= 0xDF && cp <= 0xFF && cp != 0xF7)
}

///|
/// Category membership. Returns false for a category name we do not model, which
/// makes the pattern fail loudly rather than silently matching everything.
fn in_category(cp : Int, name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  // A trailing '^' marks a negated \P{...} inside a class.
  if name.length() > 1 && code_at_b(name, name.length() - 1) == 94 {
    let inner = name[0:name.length() - 1].to_owned()
    return !in_category(cp, inner)
  }
  match name {
    "d" => is_unicode_digit(cp)
    "D" => !is_unicode_digit(cp)
    "w" =>
      is_unicode_letter(cp) || is_unicode_digit(cp) || cp == 95 ||
      (cp >= 0x300 && cp <= 0x36F)
    "W" =>
      !(is_unicode_letter(cp) ||
        is_unicode_digit(cp) ||
        cp == 95 ||
        (cp >= 0x300 && cp <= 0x36F))
    "s" => is_unicode_space(cp)
    "S" => !is_unicode_space(cp)
    "i" => is_xml_name_start(cp)
    "I" => !is_xml_name_start(cp)
    "c" => is_xml_name_char(cp)
    "C" => !is_xml_name_char(cp)
    "L" => is_unicode_letter(cp)
    "Lu" => is_unicode_upper(cp)
    "Ll" => is_unicode_lower(cp)
    "N" => is_unicode_digit(cp)
    "Nd" => is_unicode_digit(cp)
    "Z" => is_unicode_space(cp)
    "Zs" => is_unicode_space(cp)
    "IsBasicLatin" => cp >= 0 && cp <= 0x7F
    "IsLatin-1Supplement" => cp >= 0x80 && cp <= 0xFF
    _ => false
  }
}

///|
/// Tests one code point against a class.
fn class_matches(cc : CharClass, cp : Int) -> Bool {
  let mut hit = in_ranges(cp, cc.ranges)
  if !hit {
    for cat in cc.categories {
      if in_category(cp, cat) {
        hit = true
        break
      }
    }
  }
  if hit && in_ranges(cp, cc.excluded) {
    hit = false
  }
  if cc.negated {
    !hit
  } else {
    hit
  }
}

///|
/// All end offsets reachable by matching `node` at `pos`.
///
/// The matcher returns every possible end position rather than the first one,
/// because a `Concat` needs to backtrack: if one branch of an alternative leads
/// to a dead end, the next candidate has to be tried.
fn match_node(node : ReNode, s : String, pos : Int) -> Array[Int] {
  match node {
    Empty => [pos]
    Char(cp) => {
      if pos >= s.length() {
        []
      } else {
        let (actual, next) = cp_at(s, pos)
        if actual == cp {
          [next]
        } else {
          []
        }
      }
    }
    AnyChar => {
      if pos >= s.length() {
        []
      } else {
        let (cp, next) = cp_at(s, pos)
        // '.' does not match the line terminators.
        if cp == 10 || cp == 13 || cp == 0x2028 || cp == 0x2029 {
          []
        } else {
          [next]
        }
      }
    }
    Class(cc) => {
      if pos >= s.length() {
        []
      } else {
        let (cp, next) = cp_at(s, pos)
        if class_matches(cc, cp) {
          [next]
        } else {
          []
        }
      }
    }
    Alt(branches) => {
      let out : Array[Int] = []
      for b in branches {
        for e in match_node(b, s, pos) {
          push_unique(out, e)
        }
      }
      out
    }
    Concat(items) => match_concat(items, 0, s, pos)
    Repeat(inner, min, max) => match_repeat(inner, s, pos, 0, min, max)
  }
}

///|
fn push_unique(out : Array[Int], value : Int) -> Unit {
  for existing in out {
    if existing == value {
      return
    }
  }
  out.push(value)
}

///|
fn match_concat(
  items : Array[ReNode],
  index : Int,
  s : String,
  pos : Int,
) -> Array[Int] {
  if index >= items.length() {
    return [pos]
  }
  let out : Array[Int] = []
  for next in match_node(items[index], s, pos) {
    for end in match_concat(items, index + 1, s, next) {
      push_unique(out, end)
    }
  }
  out
}

///|
/// Repetition by expansion. `count` guards against infinite loops when the
/// inner node can match the empty string.
fn match_repeat(
  inner : ReNode,
  s : String,
  pos : Int,
  count : Int,
  min : Int,
  max : Int,
) -> Array[Int] {
  let out : Array[Int] = []
  if count >= min {
    push_unique(out, pos)
  }
  if max != repeat_unbounded && count >= max {
    return out
  }
  if count > 256 {
    return out
  }
  for next in match_node(inner, s, pos) {
    // A zero-width iteration would spin forever; stop expanding it.
    if next == pos {
      if count + 1 >= min {
        push_unique(out, pos)
      }
      continue
    }
    for end in match_repeat(inner, s, next, count + 1, min, max) {
      push_unique(out, end)
    }
  }
  out
}

///|
/// `pattern` facet semantics: is there *any* match inside `text`?
pub fn xsd_pattern_search(pattern : String, text : String) -> Bool {
  let node = match parse_xsd_regex(pattern) {
    Ok(n) => n
    // A malformed pattern is a schema error; treating it as "no match" keeps
    // validation total and surfaces the problem through the schema checker.
    Err(_) => return false
  }
  let mut start = 0
  while true {
    if !match_node(node, text, start).is_empty() {
      return true
    }
    if start >= text.length() {
      return false
    }
    let (_, next) = cp_at(text, start)
    start = next
  }
  false
}

///|
/// True when `text` matches the whole pattern, used by tests and by anyone who
/// needs anchoring semantics.
pub fn xsd_pattern_full_match(pattern : String, text : String) -> Bool {
  let node = match parse_xsd_regex(pattern) {
    Ok(n) => n
    Err(_) => return false
  }
  for end in match_node(node, text, 0) {
    if end == text.length() {
      return true
    }
  }
  false
}
