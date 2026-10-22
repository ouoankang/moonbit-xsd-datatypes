// The validation entry point: parse a lexical form against a simple type, then
// apply the facets that type carries.
//
// Three varieties exist in XSD: atomic, list, and union.

///|
/// A simple type: the built-in it derives from, its variety, and its facets.
pub(all) enum SimpleType {
  Atomic(String, Facets)
  ListOf(String, Facets)
  UnionOf(Array[String], Facets)
} derive(Debug)

///|
/// Builds an atomic type with no facets.
pub fn make_atomic(type_name : String) -> SimpleType {
  Atomic(type_name, no_facets())
}

///|
/// Builds an atomic type with facets.
pub fn make_atomic_with(type_name : String, facets : Facets) -> SimpleType {
  Atomic(type_name, facets)
}

///|
/// Builds a list type.
pub fn make_list(item : String, facets : Facets) -> SimpleType {
  ListOf(item, facets)
}

///|
/// Builds a union type.
pub fn make_union(members : Array[String], facets : Facets) -> SimpleType {
  UnionOf(members, facets)
}

///|
/// Applies the type's whitespace rule, which is fixed per builtin type:
/// `string` preserves, `normalizedString` replaces, everything else collapses.
fn normalize_for(type_name : String, raw : String) -> String {
  if type_name == "string" {
    raw
  } else if type_name == "normalizedString" {
    ws_replace(raw)
  } else {
    ws_collapse(raw)
  }
}

///|
/// Splits on single spaces, dropping empty pieces.
fn split_spaces(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < s.length() {
    let start = i
    while i < s.length() && code_at_b(s, i) != 32 {
      i = i + 1
    }
    if i > start {
      out.push(s[start:i].to_owned())
    }
    if i < s.length() {
      i = i + 1
    }
  }
  out
}

///|
pub fn check_value(t : SimpleType, raw : String) -> ValResult {
  match t {
    Atomic(type_name, facets) => {
      // xs:NMTOKENS / IDREFS / ENTITIES are list types baked into the builtin
      // set. Their `length` counts items, not characters, so they take the list
      // path rather than the atomic one.
      if type_name == "NMTOKENS" {
        return check_list("NMTOKEN", raw, facets)
      }
      if type_name == "IDREFS" {
        return check_list("IDREF", raw, facets)
      }
      if type_name == "ENTITIES" {
        return check_list("ENTITY", raw, facets)
      }
      // Facets see the lexical form after the type's whitespace rule, which is
      // what the specification constrains.
      let normalized = normalize_for(type_name, raw)
      let parsed = match parse_builtin(type_name, raw) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      match apply_facets(parsed, normalized, facets) {
        Ok(_) => Ok(parsed)
        Err(e) => Err(e)
      }
    }
    ListOf(item, facets) => check_list(item, raw, facets)
    // A union's whiteSpace is fixed at collapse, regardless of what its members
    // prescribe, so the raw form is folded before any member sees it.
    UnionOf(members, facets) => check_union(members, ws_collapse(raw), facets)
  }
}

///|
fn check_list(item : String, raw : String, facets : Facets) -> ValResult {
  let collapsed = ws_collapse(raw)
  if collapsed.is_empty() {
    return Err(Lexical("list value has no items"))
  }
  let items = split_spaces(collapsed)
  for it in items {
    match check_value(make_atomic(item), it) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let n = items.length()
  match facets.length {
    Some(want) =>
      if n != want {
        return Err(Facet("list has \{n} items, expected \{want}"))
      }
    None => ()
  }
  match facets.min_length {
    Some(want) =>
      if n < want {
        return Err(Facet("list has fewer than \{want} items"))
      }
    None => ()
  }
  match facets.max_length {
    Some(want) =>
      if n > want {
        return Err(Facet("list has more than \{want} items"))
      }
    None => ()
  }
  check_pattern_and_enumeration(Str(collapsed), collapsed, facets)
}

///|
fn check_union(members : Array[String], raw : String, facets : Facets) -> ValResult {
  let mut accepted : XsdValue? = None
  for m in members {
    match check_value(make_atomic(m), raw) {
      Ok(v) => {
        accepted = Some(v)
        break
      }
      Err(_) => ()
    }
  }
  match accepted {
    None => Err(Lexical("value matches no member of the union"))
    Some(v) =>
      match apply_facets(v, raw, facets) {
        Ok(_) => Ok(v)
        Err(e) => Err(e)
      }
  }
}

///|
/// Applies only the facets that make sense for a whole list value.
fn check_pattern_and_enumeration(
  v : XsdValue,
  raw : String,
  facets : Facets,
) -> ValResult {
  let rest = Facets::{
    length: None,
    min_length: None,
    max_length: None,
    patterns: facets.patterns,
    enumeration: facets.enumeration,
    max_inclusive: facets.max_inclusive,
    max_exclusive: facets.max_exclusive,
    min_inclusive: facets.min_inclusive,
    min_exclusive: facets.min_exclusive,
    total_digits: facets.total_digits,
    fraction_digits: facets.fraction_digits,
  }
  match apply_facets(v, raw, rest) {
    Ok(_) => Ok(v)
    Err(e) => Err(e)
  }
}

///|
/// Convenience: validate against a built-in type by name, with no facets.
pub fn validate_builtin(type_name : String, raw : String) -> ValResult {
  check_value(make_atomic(type_name), raw)
}

///|
/// Convenience: does this string belong to the lexical space of the type?
pub fn is_valid_lexical(type_name : String, raw : String) -> Bool {
  match validate_builtin(type_name, raw) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
/// The XSD namespace URI.
pub let xsd_namespace : String = "http://www.w3.org/2001/XMLSchema"

///|
/// Strips an `xs:` / `xsd:` prefix from a type reference and returns the local
/// name, or None when the reference points outside the built-in namespace.
pub fn builtin_local_name(reference : String) -> Option[String] {
  let idx = reference.find(":")
  match idx {
    None => Some(reference)
    Some(i) =>
      match reference[0:i].to_owned() {
        "xs" | "xsd" => Some(reference[i + 1:reference.length()].to_owned())
        _ => None
      }
  }
}
