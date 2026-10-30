// The value model: what a lexical form becomes after it is parsed.
//
// XSD separates the *lexical space* (which strings are allowed) from the
// *value space* (what those strings denote). Facets and ordering operate on the
// value space, so every type has to produce one of these representations.

///|
/// An arbitrary-precision decimal.
///
/// XSD's `decimal` has no exponent and no upper bound on digits, so `Double` is
/// not usable: `1.0000000000000000000001` must not collapse into `1`. This
/// representation keeps the digits as text and only converts when comparing.
///
/// Invariants after `normalize`: `int_part` has no leading zeros and is never
/// empty; `frac_part` has no trailing zeros and may be empty; zero is never
/// negative.
pub struct Decimal {
  negative : Bool
  int_part : String
  frac_part : String
} derive(Debug, Eq)

pub extend Decimal with @debug.Debug::{to_repr}

pub extend Decimal with Eq::{not_equal, equal}

///|
/// Which calendar-ish shape a temporal value has. The fields that are absent
/// for a given kind are simply not displayed, but the struct carries them all
/// so that one comparison routine can order any two compatible values.
pub enum TemporalKind {
  DateTime
  Date
  Time
  GYearMonth
  GYear
  GMonthDay
  GDay
  GMonth
} derive(Debug, Eq)

pub extend TemporalKind with @debug.Debug::{to_repr}
pub extend TemporalKind with Eq::{not_equal, equal}

///|
/// A parsed temporal value.
///
/// `tz` is the offset from UTC in minutes, or `None` when the lexical form had
/// no timezone. `frac_part` holds the digits after the decimal point of the
/// seconds field, without trailing zeros.
pub struct Temporal {
  kind : TemporalKind
  year : Int
  month : Int
  day : Int
  hour : Int
  minute : Int
  second : Int
  frac_part : String
  tz : Int?
  /// Set when the lexical form carried a negative year (`-0044`).
  year_negative : Bool
} derive(Debug, Eq)

pub extend Temporal with @debug.Debug::{to_repr}
pub extend Temporal with Eq::{not_equal, equal}

///|
/// A duration. XSD decomposes durations into a month part and a second part
/// because the two never mix: a month is not a fixed number of seconds, so
/// `P1M` and `P30D` are different values that may or may not compare equal.
pub struct Duration {
  negative : Bool
  months : Int
  seconds : Decimal
} derive(Debug, Eq)

pub extend Duration with @debug.Debug::{to_repr}
pub extend Duration with Eq::{not_equal, equal}

///|
/// A QName as it appears in a lexical form: an optional prefix plus a local
/// name. Binding the prefix to a URI needs schema context that a bare lexical
/// value does not carry, so validation checks the shape only.
pub struct QNameValue {
  prefix : String
  local_name : String
} derive(Debug, Eq)

pub extend QNameValue with @debug.Debug::{to_repr}
pub extend QNameValue with Eq::{not_equal, equal}

///|
/// A `float` or `double` value.
///
/// A finite value is stored as the machine float that XSD's value space is
/// defined over: IEEE 754 binary64 for `double`, binary32 widened to binary64
/// for `float`.
///
/// Storing the digits instead would be wrong. `0.1` and
/// `0.1000000000000000055511151231257827` denote the same double, so an
/// `enumeration` written as the former has to accept the latter; comparing
/// decimal strings would reject it. The rounding that makes them equal is
/// exactly what the value space prescribes, so it has to happen at parse time.
pub(all) enum FloatValue {
  Finite(Double)
  PosInf
  NegInf
  NotANumber
} derive(Debug, Eq)
pub extend FloatValue with @debug.Debug::{to_repr}
pub extend FloatValue with Eq::{not_equal, equal}


///|
/// A `hexBinary` or `base64Binary` value.
///
/// `canonical` is the value re-encoded in the canonical form of its own type
/// (lowercase hex, or standard base64 with padding) so that two spellings of the
/// same octets compare equal. `len_bytes` is what the `length` facet measures.
pub struct Octets {
  canonical : String
  len_bytes : Int
} derive(Debug, Eq)

pub extend Octets with @debug.Debug::{to_repr}
pub extend Octets with Eq::{not_equal, equal}

///|
/// A value in the XSD value space.
pub(all) enum XsdValue {
  Str(String)
  Bool(Bool)
  Dec(Decimal)
  Flt(FloatValue)
  Temporal(Temporal)
  Dur(Duration)
  Bin(Octets)
  Uri(String)
  Qn(QNameValue)
  Not(String)
} derive(Debug)

pub extend XsdValue with @debug.Debug::{to_repr}

///|
/// Why a lexical form or a facet check failed.
pub(all) enum ValErr {
  /// The string is not in the lexical space of the type.
  Lexical(String)
  /// The value parsed but violated a facet.
  Facet(String)
} derive(Debug, Eq)

pub extend ValErr with @debug.Debug::{to_repr}
pub extend ValErr with Eq::{not_equal, equal}
pub extend ValErr with Show::{to_string, output}

///|
pub impl Show for ValErr with fn to_string(self) {
  match self {
    Lexical(reason) => "invalid lexical form: \{reason}"
    Facet(reason) => "facet violation: \{reason}"
  }
}

///|
/// Builds a `Lexical` error.
pub fn lexical(reason : String) -> ValErr {
  Lexical(reason)
}

///|
/// Builds a `Facet` error.
pub fn facet(reason : String) -> ValErr {
  Facet(reason)
}

///|
/// The result type used throughout this package.
pub type ValResult = Result[XsdValue, ValErr]
