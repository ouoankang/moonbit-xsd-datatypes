name = "ouoankang/moonbit-xsd-datatypes"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/ouoankang/moonbit-xsd-datatypes"

license = "Apache-2.0"

keywords = [
  "xml",
  "xsd",
  "xml-schema",
  "datatype",
  "validation",
  "w3c",
]

preferred_target = "wasm-gc"

supported_targets = [ "wasm-gc", "js" ]

description = "XSD 1.0 datatype validation for MoonBit: lexical-space parsing and facet checking for the built-in simple types."

import {
  "moonbitlang/x@0.5.5",
}
