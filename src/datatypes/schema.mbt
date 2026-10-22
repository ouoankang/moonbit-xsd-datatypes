// Reading a schema document into the simple types it declares.
//
// This is the layer that makes the library usable on real XSD: it walks
// `xs:simpleType` definitions and `xs:element` declarations, turns each
// `restriction` / `list` / `union` into a `SimpleType`, and reads the facets
// attached to a restriction.
//
// Elements matter because real schemas rarely declare a named type just to use
// it once: they inline an anonymous `simpleType` inside the element. The W3C
// conformance data is written that way throughout.

///|
/// A schema: named simple types plus element declarations, both keyed by name.
pub struct Schema {
  declared : Map[String, SimpleType]
  elements : Map[String, SimpleType]
} derive(Debug)

///|
/// An empty schema.
pub fn empty_schema() -> Schema {
  { declared: Map([], capacity=0), elements: Map([], capacity=0) }
}

///|
/// Looks up a declared simple type by name.
pub fn Schema::get(self : Schema, name : String) -> SimpleType? {
  self.declared.get(name)
}

///|
/// Looks up the type of a declared element by name.
pub fn Schema::element_type(self : Schema, name : String) -> SimpleType? {
  self.elements.get(name)
}

///|
/// Reads `value` of a child facet element.
fn facet_value(el : @xml.XmlElement) -> String? {
  @xml.attr_value(el, "", "value")
}

///|
/// Resolves a `base` / `itemType` reference to a type.
///
/// Three spellings reach here: `xs:decimal` (builtin with a prefix), `ID`
/// (builtin because the document makes XSD the default namespace), and
/// `nist:someType` (a type declared in this document). Only the last needs a
/// lookup, and a miss falls back to the builtin table so the error surfaces
/// when the value is parsed, where the message names the type.
fn resolve_type(type_ref : String, schema : Schema) -> Result[SimpleType, ValErr] {
  let local_name = match type_ref.find(":") {
    Some(i) => type_ref[i + 1:type_ref.length()].to_owned()
    None => type_ref
  }
  if local_name == type_ref {
    // No prefix: local type if declared, otherwise a builtin without prefix.
    match schema.declared.get(type_ref) {
      Some(t) => Ok(t)
      None => Ok(make_atomic(type_ref))
    }
  } else {
    let colon = match type_ref.find(":") {
      Some(i) => i
      None => 0
    }
    let prefix = type_ref[0:colon].to_owned()
    if prefix == "xs" || prefix == "xsd" {
      return Ok(make_atomic(local_name))
    }
    // Any other prefix is the document's own namespace.
    match schema.declared.get(local_name) {
      Some(t) => Ok(t)
      None => Ok(make_atomic(local_name))
    }
  }
}

///|
/// Non-negative integer used by the digit and length facets.
fn parse_uint_strict(s : String) -> Int? {
  let t = ws_collapse(s)
  if t.is_empty() {
    return None
  }
  let mut v = 0
  let mut i = 0
  while i < t.length() {
    let c = code_at_b(t, i)
    if c < 48 || c > 57 {
      return None
    }
    v = v * 10 + (c - 48)
    i = i + 1
  }
  Some(v)
}

///|
/// Reads the facets inside a `xs:restriction` element.
///
/// Values accumulate in locals and the struct is built once at the end. Mixing
/// record update with in-place pushes on the same array is easy to get wrong,
/// because a later update can shadow an earlier push.
fn read_facets(
  restriction : @xml.XmlElement,
  base : String,
) -> Result[Facets, ValErr] {
  let mut length : Int? = None
  let mut min_length : Int? = None
  let mut max_length : Int? = None
  let patterns : Array[String] = Array(capacity=0)
  let enumeration : Array[XsdValue] = Array(capacity=0)
  let mut max_inclusive : XsdValue? = None
  let mut max_exclusive : XsdValue? = None
  let mut min_inclusive : XsdValue? = None
  let mut min_exclusive : XsdValue? = None
  let mut total_digits : Int? = None
  let mut fraction_digits : Int? = None
  for node in restriction.children {
    match node {
      Text(_) => ()
      Element(child) => {
        if child.name.uri != xsd_namespace {
          continue
        }
        let facet_name = child.name.local_name
        if facet_name == "annotation" ||
          facet_name == "simpleType" ||
          facet_name == "whiteSpace" {
          continue
        }
        let raw = match facet_value(child) {
          Some(v) => v
          None => return Err(Lexical("facet \{facet_name} needs a value"))
        }
        if facet_name == "pattern" {
          patterns.push(raw)
          continue
        }
        if facet_name == "enumeration" {
          match validate_builtin(base, raw) {
            Ok(v) => enumeration.push(v)
            Err(e) =>
              return Err(
                Lexical(
                  "enumeration value \"\{ws_collapse(raw)}\" rejected by base \{base}: \{e}",
                ),
              )
          }
          continue
        }
        if facet_name == "length" ||
          facet_name == "minLength" ||
          facet_name == "maxLength" ||
          facet_name == "totalDigits" ||
          facet_name == "fractionDigits" {
          let n = match parse_uint_strict(raw) {
            Some(v) => v
            None =>
              return Err(
                Lexical("facet \{facet_name} needs a non-negative integer"),
              )
          }
          if facet_name == "length" {
            length = Some(n)
          } else if facet_name == "minLength" {
            min_length = Some(n)
          } else if facet_name == "maxLength" {
            max_length = Some(n)
          } else if facet_name == "totalDigits" {
            total_digits = Some(n)
          } else {
            fraction_digits = Some(n)
          }
          continue
        }
        let bound = match validate_builtin(base, raw) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if facet_name == "maxInclusive" {
          max_inclusive = Some(bound)
        } else if facet_name == "maxExclusive" {
          max_exclusive = Some(bound)
        } else if facet_name == "minInclusive" {
          min_inclusive = Some(bound)
        } else if facet_name == "minExclusive" {
          min_exclusive = Some(bound)
        } else {
          return Err(Lexical("unsupported facet: \{facet_name}"))
        }
      }
    }
  }
  Ok(Facets::{
    length,
    min_length,
    max_length,
    patterns: if patterns.is_empty() { [] } else { [patterns] },
    enumeration,
    max_inclusive,
    max_exclusive,
    min_inclusive,
    min_exclusive,
    total_digits,
    fraction_digits,
  })
}

///|
/// Parses one `xs:simpleType` element into a `SimpleType`.
fn parse_simple_type(
  el : @xml.XmlElement,
  schema : Schema,
) -> Result[SimpleType, ValErr] {
  for node in el.children {
    match node {
      Text(_) => ()
      Element(child) => {
        if child.name.uri != xsd_namespace {
          continue
        }
        let variety = child.name.local_name
        if variety == "restriction" {
          let base = match @xml.attr_value(child, "", "base") {
            Some(b) => b
            None => return Err(Lexical("restriction needs a base"))
          }
          let base_type = match resolve_type(base, schema) {
            Ok(t) => t
            Err(e) => return Err(e)
          }
          // Facet values are parsed against the base. For a list or union base
          // there is no single lexical space to parse against, so string is
          // used: enumeration values on a list are compared as the collapsed
          // list text, which is what validation produces anyway.
          let facet_base = match base_type {
            Atomic(n, _) => n
            _ => "string"
          }
          let facets = match read_facets(child, facet_base) {
            Ok(f) => f
            Err(e) => return Err(e)
          }
          // A restriction keeps the variety of its base. Most facets are
          // replaced (a valid restriction only narrows, so the new value already
          // implies the old one), but patterns accumulate: each step contributes
          // its own group and all groups must hold.
          let base_facets = match base_type {
            Atomic(_, bf) => bf
            ListOf(_, bf) => bf
            UnionOf(_, bf) => bf
          }
          let merged = Facets::{
            length: facets.length,
            min_length: facets.min_length,
            max_length: facets.max_length,
            patterns: base_facets.patterns + facets.patterns,
            enumeration: facets.enumeration,
            max_inclusive: facets.max_inclusive,
            max_exclusive: facets.max_exclusive,
            min_inclusive: facets.min_inclusive,
            min_exclusive: facets.min_exclusive,
            total_digits: facets.total_digits,
            fraction_digits: facets.fraction_digits,
          }
          return Ok(
            match base_type {
              Atomic(n, _) => Atomic(n, merged)
              ListOf(i, _) => ListOf(i, merged)
              UnionOf(ms, _) => UnionOf(ms, merged)
            },
          )
        }
        if variety == "list" {
          let item = match @xml.attr_value(child, "", "itemType") {
            Some(b) => b
            None => return Err(Lexical("list needs an itemType"))
          }
          let item_type = match resolve_type(item, schema) {
            Ok(t) => t
            Err(e) => return Err(e)
          }
          match item_type {
            Atomic(n, _) => return Ok(ListOf(n, no_facets()))
            _ => return Err(Lexical("list item type must be atomic"))
          }
        }
        if variety == "union" {
          let members = match @xml.attr_value(child, "", "memberTypes") {
            Some(m) => m
            None => return Err(Lexical("union needs memberTypes"))
          }
          let names : Array[String] = Array(capacity=0)
          for part in split_spaces(ws_collapse(members)) {
            let member_type = match resolve_type(part, schema) {
              Ok(t) => t
              Err(e) => return Err(e)
            }
            match member_type {
              Atomic(n, _) => names.push(n)
              _ => return Err(Lexical("union member type must be atomic"))
            }
          }
          if names.is_empty() {
            return Err(Lexical("union has no members"))
          }
          return Ok(UnionOf(names, no_facets()))
        }
        if variety == "annotation" {
          continue
        }
        return Err(Lexical("unsupported simpleType variety: \{variety}"))
      }
    }
  }
  Err(Lexical("simpleType has no definition"))
}

///|
/// Collects every named `xs:simpleType` in the document.
fn collect_simple_types(
  el : @xml.XmlElement,
  schema : Schema,
) -> Result[Unit, ValErr] {
  if el.name.uri == xsd_namespace && el.name.local_name == "simpleType" {
    match @xml.attr_value(el, "", "name") {
      Some(name) => {
        let t = match parse_simple_type(el, schema) {
          Ok(t) => t
          Err(e) => return Err(e)
        }
        schema.declared.set(name, t)
      }
      None => ()
    }
  }
  for node in el.children {
    match node {
      Element(child) =>
        match collect_simple_types(child, schema) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      Text(_) => ()
    }
  }
  Ok(())
}

///|
/// Works out the simple type of an `xs:element`, either from its `type`
/// attribute or from an inline anonymous `simpleType`.
fn element_simple_type(
  el : @xml.XmlElement,
  schema : Schema,
) -> Result[SimpleType?, ValErr] {
  match @xml.attr_value(el, "", "type") {
    Some(t) => {
      let ty = match resolve_type(t, schema) {
        Ok(n) => n
        Err(e) => return Err(e)
      }
      Ok(Some(ty))
    }
    None => {
      for node in el.children {
        match node {
          Element(child) =>
            if child.name.uri == xsd_namespace &&
              child.name.local_name == "simpleType" {
              let t = match parse_simple_type(child, schema) {
                Ok(t) => t
                Err(e) => return Err(e)
              }
              return Ok(Some(t))
            }
          Text(_) => ()
        }
      }
      Ok(None)
    }
  }
}

///|
/// Collects element declarations that resolve to a simple type. Complex elements
/// are skipped: this library validates values, not content models.
fn collect_elements(
  el : @xml.XmlElement,
  schema : Schema,
) -> Result[Unit, ValErr] {
  if el.name.uri == xsd_namespace && el.name.local_name == "element" {
    match @xml.attr_value(el, "", "name") {
      Some(name) => {
        match element_simple_type(el, schema) {
          Ok(Some(t)) => schema.elements.set(name, t)
          // No simple type (an element with a complexType, or a ref): skip it.
          Ok(None) => ()
          Err(e) => return Err(e)
        }
      }
      None => ()
    }
  }
  for node in el.children {
    match node {
      Element(child) =>
        match collect_elements(child, schema) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      Text(_) => ()
    }
  }
  Ok(())
}

///|
/// Parses a schema document and returns its named types and elements.
pub fn load_schema(source : String) -> Result[Schema, ValErr] {
  let root = match @xml.parse_xml(source) {
    Ok(r) => r
    Err(e) => return Err(Lexical("XML: \{e}"))
  }
  if root.name.uri != xsd_namespace || root.name.local_name != "schema" {
    return Err(Lexical("root element is not xs:schema"))
  }
  let schema = empty_schema()
  // Two passes: types first, so element type references can resolve.
  match collect_simple_types(root, schema) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match collect_elements(root, schema) {
    Ok(_) => Ok(schema)
    Err(e) => Err(e)
  }
}

///|
/// Validates a value against a named type declared in the schema.
pub fn validate_named(schema : Schema, type_name : String, raw : String) -> ValResult {
  match schema.declared.get(type_name) {
    Some(t) => check_value(t, raw)
    None => Err(Lexical("no such type: \{type_name}"))
  }
}

///|
/// Validates the character content of a named element against its type.
pub fn validate_element(schema : Schema, element_name : String, raw : String) -> ValResult {
  match schema.elements.get(element_name) {
    Some(t) => check_value(t, raw)
    None => Err(Lexical("no such element: \{element_name}"))
  }
}
