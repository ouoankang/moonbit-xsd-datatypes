// Minimal namespace-aware XML reader for XSD processing.
//
// This is deliberately NOT a general XML 1.0 processor. It reads exactly what
// XML Schema documents and their instances need: elements, attributes, text,
// CDATA, comments, processing instructions, character/entity references, and
// namespace binding. DTD internal subsets, external entities, and
// well-formedness checks beyond structure are out of scope and rejected
// explicitly rather than silently ignored.

///|
/// A namespace-qualified name.
///
/// `uri` is the resolved namespace URI (empty string for "no namespace"),
/// `local_name` is the part after the colon, and `prefix` is what appeared in the
/// document. XML Schema matches on `(uri, local_name)`; the prefix itself carries
/// no meaning and two different prefixes bound to the same URI are the same
/// name.
pub struct QName {
  uri : String
  local_name : String
  prefix : String
} derive(Debug, Eq)

pub extend QName with @debug.Debug::{to_repr}
pub extend QName with Eq::{not_equal, equal}

///|
/// An attribute. Attributes never take the default namespace: an unprefixed
/// attribute is in no namespace even when a default `xmlns` is in scope
/// (Namespaces in XML 1.0, section 6.2).
pub struct XmlAttr {
  name : QName
  value : String
} derive(Debug, Eq)

pub extend XmlAttr with @debug.Debug::{to_repr}
pub extend XmlAttr with Eq::{not_equal, equal}

///|
/// A child node: either an element or a run of character data.
pub enum XmlNode {
  Element(XmlElement)
  Text(String)
} derive(Debug, Eq)

pub extend XmlNode with @debug.Debug::{to_repr}
pub extend XmlNode with Eq::{not_equal, equal}

///|
/// An element with its namespace-resolved name, attributes, and children.
pub struct XmlElement {
  name : QName
  attributes : Array[XmlAttr]
  children : Array[XmlNode]
  /// Namespace bindings declared on this element, as (prefix, uri). An empty
  /// prefix means the default namespace. Kept for error messages and for
  /// tooling that wants to re-serialize faithfully.
  ns_decls : Array[(String, String)]
} derive(Debug, Eq)

pub extend XmlElement with @debug.Debug::{to_repr}
pub extend XmlElement with Eq::{not_equal, equal}

///|
/// Why a document was rejected.
pub enum XmlError {
  /// Input ended in the middle of a construct.
  UnexpectedEof
  /// The document does not start with a `<`.
  NotAnElement
  /// A tag ended without the closing `>`.
  UnterminatedTag
  /// An end tag did not match the open element.
  MismatchedTag(String, String)
  /// A prefixed name used a prefix with no in-scope binding.
  UnboundPrefix(String)
  /// `&#...;` did not contain a valid code point.
  BadCharRef(String)
  /// `&name;` named an entity other than the five predefined ones.
  UnknownEntity(String)
  /// A construct this reader intentionally does not support (DOCTYPE,
  /// CDATA with nested `]]`, etc.).
  Unsupported(String)
  /// More than one root element.
  MultipleRoots
  /// Text appeared outside the root element.
  TextOutsideRoot
} derive(Debug, Eq)

pub extend XmlError with @debug.Debug::{to_repr}
pub extend XmlError with Eq::{not_equal, equal}

///|
/// The namespace bound to the prefix `xml`, always in scope without declaration.
pub let xml_namespace_uri : String = "http://www.w3.org/XML/1998/namespace"

///|
/// The namespace bound to `xmlns` itself. Reserved: never usable as an element
/// or attribute prefix.
pub let xmlns_namespace_uri : String = "http://www.w3.org/2000/xmlns/"

///|
pub impl Show for XmlError with fn to_string(self) {
  match self {
    UnexpectedEof => "unexpected end of input"
    NotAnElement => "document does not start with an element"
    UnterminatedTag => "unterminated tag"
    MismatchedTag(open_, close) => "mismatched tag: <\{open_}> closed by </\{close}>"
    UnboundPrefix(p) => "unbound namespace prefix: \{p}"
    BadCharRef(s) => "bad character reference: &\{s};"
    UnknownEntity(s) => "unknown entity: &\{s};"
    Unsupported(s) => "unsupported: \{s}"
    MultipleRoots => "more than one root element"
    TextOutsideRoot => "text outside the root element"
  }
}

///|
/// Explicit method promotion, required by newer toolchains.
pub extend XmlError with Show::{to_string, output}
