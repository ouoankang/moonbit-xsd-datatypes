// Tests for the namespace-aware XML reader.
//
// The cases here are chosen around the rules that actually break XSD
// processing: default namespaces applying to elements but not attributes,
// inner declarations shadowing outer ones, and unbound prefixes being an error
// rather than an empty URI.

///|
fn must_parse(src : String) -> XmlElement {
  match parse_xml(src) {
    Ok(el) => el
    Err(e) => abort("expected a successful parse, got \{e}")
  }
}

///|
test "plain element with no namespace" {
  let el = must_parse("<root/>")
  assert_eq(el.name.uri, "")
  assert_eq(el.name.local_name, "root")
  assert_eq(el.name.prefix, "")
  assert_eq(el.children.length(), 0)
}

///|
test "default namespace applies to the element" {
  let el = must_parse("<root xmlns=\"urn:example\"/>")
  assert_eq(el.name.uri, "urn:example")
  assert_eq(el.name.local_name, "root")
}

///|
test "default namespace does not apply to attributes" {
  // The single most common namespace bug: unprefixed attributes stay in no
  // namespace even though a default xmlns is in scope.
  let el = must_parse("<root xmlns=\"urn:example\" id=\"7\"/>")
  assert_eq(el.name.uri, "urn:example")
  assert_eq(attr_value(el, "", "id"), Some("7"))
  assert_eq(attr_value(el, "urn:example", "id"), None)
}

///|
test "prefixed names resolve through xmlns:prefix" {
  let el = must_parse("<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"/>")
  assert_eq(el.name.uri, "http://www.w3.org/2001/XMLSchema")
  assert_eq(el.name.local_name, "schema")
  assert_eq(el.name.prefix, "xs")
}

///|
test "different prefixes bound to the same URI are the same name" {
  let a = must_parse("<x:a xmlns:x=\"urn:x\"/>")
  let b = must_parse("<y:a xmlns:y=\"urn:x\"/>")
  assert_eq(a.name.uri, b.name.uri)
  assert_eq(a.name.local_name, b.name.local_name)
  // Name identity is (uri, local). The prefix is an artifact of how the
  // document happened to spell it, so it is deliberately not compared.
  assert_eq(a.name.uri, b.name.uri)
  assert_eq(a.name.local_name, b.name.local_name)
  assert_eq(a.name.prefix, "x")
  assert_eq(b.name.prefix, "y")
}

///|
test "inner declaration shadows the outer one" {
  let el = must_parse(
    "<a xmlns:p=\"urn:outer\"><b xmlns:p=\"urn:inner\"><p:c/></b><p:d/></a>",
  )
  let b = match child_elements(el, "", "b") {
    [one] => one
    _ => abort("expected exactly one <b>")
  }
  let c = match child_elements(b, "urn:inner", "c") {
    [one] => one
    _ => abort("expected <p:c> to resolve into urn:inner")
  }
  assert_eq(c.name.uri, "urn:inner")
  let d = match child_elements(el, "urn:outer", "d") {
    [one] => one
    _ => abort("expected <p:d> to still resolve into urn:outer")
  }
  assert_eq(d.name.uri, "urn:outer")
}

///|
test "unbound prefix is rejected, not silently empty" {
  match parse_xml("<p:a/>") {
    Ok(_) => abort("expected UnboundPrefix")
    Err(UnboundPrefix(p)) => assert_eq(p, "p")
    Err(e) => abort("expected UnboundPrefix, got \{e}")
  }
}

///|
test "mismatched end tag is rejected" {
  match parse_xml("<a></b>") {
    Ok(_) => abort("expected MismatchedTag")
    Err(MismatchedTag(open_, close)) => {
      assert_eq(open_, "a")
      assert_eq(close, "b")
    }
    Err(e) => abort("expected MismatchedTag, got \{e}")
  }
}

///|
test "text, cdata, comments and processing instructions" {
  let el = must_parse(
    "<a>one<!-- skip --><![CDATA[<raw & stuff>]]><?pi data?>two</a>",
  )
  let buf = StringBuilder()
  for node in el.children {
    match node {
      Text(t) => buf.write_string(t)
      Element(_) => ()
    }
  }
  assert_eq(buf.to_string(), "one<raw & stuff>two")
}

///|
test "character references decode, including astral code points" {
  let el = must_parse("<a>&lt;&#65;&#x42;&#x1F409;</a>")
  let t = match el.children {
    [Text(one)] => one
    _ => abort("expected one text node")
  }
  // U+1F409 is astral: one code point, two UTF-16 code units, so "<AB" plus
  // that character is 5 code units long.
  assert_eq(t.length(), 5)
  assert_eq(t[0:3].to_owned(), "<AB")
}

///|
test "attribute values decode references and keep the quote char" {
  let el = must_parse("<a t=\"x &amp; y\" u='it&apos;s'/>")
  assert_eq(attr_value(el, "", "t"), Some("x & y"))
  assert_eq(attr_value(el, "", "u"), Some("it's"))
}

///|
test "self-closing and nested children" {
  let el = must_parse("<a><b/><c><d/>text</c></a>")
  assert_eq(child_elements(el, "", "b").length(), 1)
  let c = match child_elements(el, "", "c") {
    [one] => one
    _ => abort("expected one <c>")
  }
  assert_eq(c.children.length(), 2)
}

///|
test "namespace declarations are recorded on the declaring element" {
  let el = must_parse("<a xmlns=\"urn:d\" xmlns:p=\"urn:p\"/>")
  assert_eq(el.ns_decls.length(), 2)
  assert_eq(el.ns_decls[0], ("", "urn:d"))
  assert_eq(el.ns_decls[1], ("p", "urn:p"))
}

///|
test "the xml prefix is always in scope" {
  let el = must_parse("<a xml:lang=\"zh\"/>")
  assert_eq(attr_value(el, xml_namespace_uri, "lang"), Some("zh"))
}

///|
test "doctype is refused rather than ignored" {
  match parse_xml("<!DOCTYPE a><a/>") {
    Ok(_) => abort("expected Unsupported")
    Err(Unsupported(_)) => ()
    Err(e) => abort("expected Unsupported, got \{e}")
  }
}

///|
test "duplicate roots are rejected" {
  match parse_xml("<a/><b/>") {
    Ok(_) => abort("expected MultipleRoots")
    Err(MultipleRoots) => ()
    Err(e) => abort("expected MultipleRoots, got \{e}")
  }
}

///|
test "find_first searches depth-first" {
  let el = must_parse("<a xmlns:x=\"urn:x\"><b><x:target k=\"v\"/></b></a>")
  let found = match find_first(el, "urn:x", "target") {
    Some(t) => t
    None => abort("expected to find x:target")
  }
  assert_eq(attr_value(found, "", "k"), Some("v"))
}
