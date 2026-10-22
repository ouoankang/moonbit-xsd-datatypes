// Temporal types: dateTime, date, time, and the g* partial forms.
//
// These share one parser because they differ only in which fields are present
// and which separators are legal. Parsing is strict on purpose: `2026-02-30` is
// a lexical-space member by shape but not by value, and XSD requires rejecting
// it.

///|
fn code_at_dt(s : String, i : Int) -> Int {
  if i < 0 || i >= s.length() {
    -1
  } else {
    s.code_unit_at(i).to_int()
  }
}

///|
fn is_digit_dt(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
fn is_leap(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn days_in_month(year : Int, month : Int) -> Int {
  match month {
    1 => 31
    2 => if is_leap(year) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
/// A cursor over the lexical form, so each field reader can advance it.
priv struct DtCursor {
  src : String
  mut pos : Int
}

///|
fn DtCursor::peek(self : DtCursor) -> Int {
  code_at_dt(self.src, self.pos)
}

///|
fn DtCursor::eof(self : DtCursor) -> Bool {
  self.pos >= self.src.length()
}

///|
fn DtCursor::eat(self : DtCursor, c : Int) -> Bool {
  if self.peek() == c {
    self.pos = self.pos + 1
    true
  } else {
    false
  }
}

///|
/// Reads exactly `n` digits as an Int. Returns None when fewer than `n` digits
/// are present or any of them is not a digit.
fn DtCursor::digits(self : DtCursor, n : Int) -> Int? {
  let start = self.pos
  let mut i = 0
  let mut value = 0
  while i < n {
    let c = self.peek()
    if !is_digit_dt(c) {
      self.pos = start
      return None
    }
    value = value * 10 + (c - 48)
    self.pos = self.pos + 1
    i = i + 1
  }
  Some(value)
}

///|
/// Reads one or more digits with no upper bound on the count.
fn DtCursor::many_digits(self : DtCursor) -> Int? {
  let start = self.pos
  let mut value = 0
  while is_digit_dt(self.peek()) {
    value = value * 10 + (self.peek() - 48)
    self.pos = self.pos + 1
  }
  if self.pos == start {
    None
  } else {
    Some(value)
  }
}

///|
/// Parses the optional timezone: `Z`, `+hh:mm`, or `-hh:mm`. Returns the offset
/// in minutes. Absence yields None rather than Some(0), because "no timezone"
/// and "UTC" are different values in XSD.
fn DtCursor::timezone(self : DtCursor) -> Result[Int?, ValErr] {
  if self.eat(90) {
    // 'Z'
    return Ok(Some(0))
  }
  let sign = self.peek()
  if sign != 43 && sign != 45 {
    return Ok(None)
  }
  self.pos = self.pos + 1
  let hh = match self.digits(2) {
    Some(v) => v
    None => return Err(Lexical("timezone hour must be two digits"))
  }
  if !self.eat(58) {
    return Err(Lexical("timezone must be hh:mm"))
  }
  let mm = match self.digits(2) {
    Some(v) => v
    None => return Err(Lexical("timezone minute must be two digits"))
  }
  if hh > 14 {
    return Err(Lexical("timezone offset beyond 14 hours"))
  }
  if mm > 59 {
    return Err(Lexical("timezone minute beyond 59"))
  }
  if hh == 14 && mm != 0 {
    return Err(Lexical("timezone offset beyond 14 hours"))
  }
  let total = hh * 60 + mm
  Ok(Some(if sign == 45 { -total } else { total }))
}

///|
/// Parses `hh:mm:ss` with an optional fractional second.
fn DtCursor::time_fields(
  self : DtCursor,
) -> Result[(Int, Int, Int, String), ValErr] {
  let hh = match self.digits(2) {
    Some(v) => v
    None => return Err(Lexical("hour must be two digits"))
  }
  if !self.eat(58) {
    return Err(Lexical("time needs hh:mm:ss"))
  }
  let mi = match self.digits(2) {
    Some(v) => v
    None => return Err(Lexical("minute must be two digits"))
  }
  if !self.eat(58) {
    return Err(Lexical("time needs hh:mm:ss"))
  }
  let ss = match self.digits(2) {
    Some(v) => v
    None => return Err(Lexical("second must be two digits"))
  }
  let mut frac = ""
  if self.eat(46) {
    let start = self.pos
    while is_digit_dt(self.peek()) {
      self.pos = self.pos + 1
    }
    if self.pos == start {
      return Err(Lexical("fractional second has no digits"))
    }
    let raw = self.src[start:self.pos].to_owned()
    // Strip trailing zeros; the fractional part is a value, not a string.
    let mut n = raw.length()
    while n > 0 && code_at_dt(raw, n - 1) == 48 {
      n = n - 1
    }
    frac = raw[0:n].to_owned()
  }
  Ok((hh, mi, ss, frac))
}

///|
/// Range checks that apply once the fields are separated.
fn check_time_range(
  hh : Int,
  mi : Int,
  ss : Int,
  frac : String,
) -> Result[Unit, ValErr] {
  if hh > 24 {
    return Err(Lexical("hour out of range"))
  }
  if mi > 59 {
    return Err(Lexical("minute out of range"))
  }
  if ss > 59 {
    return Err(Lexical("second out of range"))
  }
  // 24:00:00 is legal and denotes the end of the day; 24:00:01 is not.
  if hh == 24 {
    if mi != 0 || ss != 0 || !frac.is_empty() {
      return Err(Lexical("24:00:00 is the only legal value in hour 24"))
    }
  }
  Ok(())
}

///|
/// Parses a `dateTime`.
pub fn parse_date_time(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let mut year_negative = false
  if c.eat(45) {
    year_negative = true
  }
  let year = match c.many_digits() {
    Some(v) => v
    None => return Err(Lexical("dateTime needs a year"))
  }
  if year > 9999 {
    return Err(Lexical("year beyond 9999 is not supported"))
  }
  if !c.eat(45) {
    return Err(Lexical("dateTime needs YYYY-MM-DD"))
  }
  let month = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("month must be two digits"))
  }
  if !c.eat(45) {
    return Err(Lexical("dateTime needs YYYY-MM-DD"))
  }
  let day = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("day must be two digits"))
  }
  if !c.eat(84) {
    // 'T'
    return Err(Lexical("dateTime needs a 'T' separator"))
  }
  let (hh, mi, ss, frac) = match c.time_fields() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in dateTime"))
  }
  if month < 1 || month > 12 {
    return Err(Lexical("month out of range"))
  }
  if day < 1 || day > days_in_month(year, month) {
    return Err(Lexical("day out of range for the month"))
  }
  match check_time_range(hh, mi, ss, frac) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok({
    kind: DateTime,
    year,
    month,
    day,
    hour: hh,
    minute: mi,
    second: ss,
    frac_part: frac,
    tz,
    year_negative,
  })
}

///|
/// Parses a `date`.
pub fn parse_date(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let mut year_negative = false
  if c.eat(45) {
    year_negative = true
  }
  let year = match c.many_digits() {
    Some(v) => v
    None => return Err(Lexical("date needs a year"))
  }
  if year > 9999 {
    return Err(Lexical("year beyond 9999 is not supported"))
  }
  if !c.eat(45) {
    return Err(Lexical("date needs YYYY-MM-DD"))
  }
  let month = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("month must be two digits"))
  }
  if !c.eat(45) {
    return Err(Lexical("date needs YYYY-MM-DD"))
  }
  let day = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("day must be two digits"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in date"))
  }
  if month < 1 || month > 12 {
    return Err(Lexical("month out of range"))
  }
  if day < 1 || day > days_in_month(year, month) {
    return Err(Lexical("day out of range for the month"))
  }
  Ok({
    kind: Date,
    year,
    month,
    day,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative,
  })
}

///|
/// Parses a `time`.
pub fn parse_time(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let (hh, mi, ss, frac) = match c.time_fields() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in time"))
  }
  match check_time_range(hh, mi, ss, frac) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok({
    kind: Time,
    year: 0,
    month: 0,
    day: 0,
    hour: hh,
    minute: mi,
    second: ss,
    frac_part: frac,
    tz,
    year_negative: false,
  })
}

///|
/// Reads `--` and then an optional trailing `--`, which XSD 1.0 writes for
/// `gMonth` but which many documents omit.
fn DtCursor::leading_dashes(self : DtCursor) -> Result[Unit, ValErr] {
  if !self.eat(45) || !self.eat(45) {
    return Err(Lexical("g* types start with '--'"))
  }
  Ok(())
}

///|
/// Parses `gYearMonth` (`YYYY-MM`).
pub fn parse_g_year_month(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let mut year_negative = false
  if c.eat(45) {
    year_negative = true
  }
  let year = match c.many_digits() {
    Some(v) => v
    None => return Err(Lexical("gYearMonth needs a year"))
  }
  if !c.eat(45) {
    return Err(Lexical("gYearMonth needs YYYY-MM"))
  }
  let month = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("month must be two digits"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in gYearMonth"))
  }
  if month < 1 || month > 12 {
    return Err(Lexical("month out of range"))
  }
  Ok({
    kind: GYearMonth,
    year,
    month,
    day: 1,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative,
  })
}

///|
/// Parses `gYear` (`YYYY`).
pub fn parse_g_year(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let mut year_negative = false
  if c.eat(45) {
    year_negative = true
  }
  let year = match c.many_digits() {
    Some(v) => v
    None => return Err(Lexical("gYear needs a year"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in gYear"))
  }
  Ok({
    kind: GYear,
    year,
    month: 1,
    day: 1,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative,
  })
}

///|
/// Parses `gMonthDay` (`--MM-DD`).
pub fn parse_g_month_day(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  match c.leading_dashes() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let month = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("gMonthDay needs MM-DD"))
  }
  if !c.eat(45) {
    return Err(Lexical("gMonthDay needs MM-DD"))
  }
  let day = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("gMonthDay needs MM-DD"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in gMonthDay"))
  }
  if month < 1 || month > 12 {
    return Err(Lexical("month out of range"))
  }
  // February is checked against a leap year so that --02-29 is accepted.
  if day < 1 || day > days_in_month(2000, month) {
    return Err(Lexical("day out of range for the month"))
  }
  Ok({
    kind: GMonthDay,
    year: 2000,
    month,
    day,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative: false,
  })
}

///|
/// Parses `gDay` (`---DD`).
pub fn parse_g_day(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  match c.leading_dashes() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if !c.eat(45) {
    return Err(Lexical("gDay starts with '---'"))
  }
  let day = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("gDay needs a two digit day"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in gDay"))
  }
  if day < 1 || day > 31 {
    return Err(Lexical("day out of range"))
  }
  Ok({
    kind: GDay,
    year: 2000,
    month: 1,
    day,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative: false,
  })
}

///|
/// Parses `gMonth` (`--MM` or `--MM--`).
pub fn parse_g_month(s : String) -> Result[Temporal, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  match c.leading_dashes() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let month = match c.digits(2) {
    Some(v) => v
    None => return Err(Lexical("gMonth needs MM"))
  }
  // XSD 1.0 spells gMonth as `--MM--`. Accept the bare form too; it is what
  // XSD 1.1 allows and what people actually write.
  if c.eat(45) && !c.eat(45) {
    return Err(Lexical("gMonth trailing '--' must be complete"))
  }
  let tz = match c.timezone() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !c.eof() {
    return Err(Lexical("trailing characters in gMonth"))
  }
  if month < 1 || month > 12 {
    return Err(Lexical("month out of range"))
  }
  Ok({
    kind: GMonth,
    year: 2000,
    month,
    day: 1,
    hour: 0,
    minute: 0,
    second: 0,
    frac_part: "",
    tz,
    year_negative: false,
  })
}

///|
/// Parses `duration`: `-?PnYnMnDTnHnMnS` with at least one field present.
///
/// The designator letters may not be reordered, and a `T` with nothing after it
/// is illegal.
pub fn parse_duration(s : String) -> Result[Duration, ValErr] {
  let c : DtCursor = { src: s, pos: 0 }
  let mut negative = false
  if c.eat(45) {
    negative = true
  }
  if !c.eat(80) {
    // 'P'
    return Err(Lexical("duration must start with 'P'"))
  }
  let mut months = 0
  let mut seconds = decimal_zero()
  let mut seen_any = false
  let mut in_time = false
  // Date part: Y, M, D in that order.
  let mut date_order = 0
  while !c.eof() {
    let ch = c.peek()
    if ch == 84 {
      // 'T'
      if in_time {
        return Err(Lexical("duration has more than one 'T'"))
      }
      in_time = true
      c.pos = c.pos + 1
      if c.eof() {
        return Err(Lexical("duration 'T' must be followed by a time part"))
      }
      continue
    }
    if !is_digit_dt(ch) {
      return Err(Lexical("duration needs a number before each designator"))
    }
    let start = c.pos
    while is_digit_dt(c.peek()) {
      c.pos = c.pos + 1
    }
    let digits = c.src[start:c.pos].to_owned()
    let mut frac = ""
    if c.eat(46) {
      let fs = c.pos
      while is_digit_dt(c.peek()) {
        c.pos = c.pos + 1
      }
      if c.pos == fs {
        return Err(Lexical("duration fractional part has no digits"))
      }
      frac = c.src[fs:c.pos].to_owned()
    }
    let unit = c.peek()
    c.pos = c.pos + 1
    seen_any = true
    if !in_time {
      let order = match unit {
        89 => 1 // Y
        77 => 2 // M
        68 => 3 // D
        _ => return Err(Lexical("unknown date designator in duration"))
      }
      if order <= date_order {
        return Err(Lexical("duration date fields are out of order"))
      }
      date_order = order
      if !frac.is_empty() {
        return Err(Lexical("only seconds may have a fraction in a duration"))
      }
      let n = match parse_uint(digits) {
        Some(v) => v
        None => return Err(Lexical("duration number too large"))
      }
      match unit {
        89 => months = months + n * 12
        77 => months = months + n
        68 => seconds = decimal_add(seconds, decimal_of(false, "\{n * 86400}", ""))
        _ => ()
      }
    } else {
      let order = match unit {
        72 => 1 // H
        77 => 2 // M
        83 => 3 // S
        _ => return Err(Lexical("unknown time designator in duration"))
      }
      if order <= date_order - 10 {
        return Err(Lexical("duration time fields are out of order"))
      }
      date_order = 10 + order
      if order != 3 && !frac.is_empty() {
        return Err(Lexical("only seconds may have a fraction in a duration"))
      }
      let n = match parse_uint(digits) {
        Some(v) => v
        None => return Err(Lexical("duration number too large"))
      }
      match unit {
        72 => seconds = decimal_add(seconds, decimal_of(false, "\{n * 3600}", ""))
        77 => seconds = decimal_add(seconds, decimal_of(false, "\{n * 60}", ""))
        83 => {
          let whole = decimal_of(false, digits, frac)
          seconds = decimal_add(seconds, whole)
        }
        _ => ()
      }
    }
  }
  if !seen_any {
    return Err(Lexical("duration has no fields"))
  }
  Ok({ negative, months, seconds })
}

///|
/// Exact addition of two non-negative decimals with the same sign, used only by
/// the duration parser to accumulate its time fields.
pub fn decimal_add(a : Decimal, b : Decimal) -> Decimal {
  let scale = if a.frac_part.length() > b.frac_part.length() {
    a.frac_part.length()
  } else {
    b.frac_part.length()
  }
  let av = decimal_scale_to_int(a, scale)
  let bv = decimal_scale_to_int(b, scale)
  let sum = av + bv
  let divisor = pow10_int(scale)
  let int_part = "\{sum / divisor}"
  let frac_raw = "\{sum % divisor}"
  let mut frac = frac_raw
  let mut pad = scale - frac_raw.length()
  while pad > 0 {
    frac = "0\{frac}"
    pad = pad - 1
  }
  decimal_of(false, int_part, frac)
}

///|
fn pow10_int(n : Int) -> Int {
  let mut p = 1
  let mut i = 0
  while i < n {
    p = p * 10
    i = i + 1
  }
  p
}

///|
fn decimal_scale_to_int(d : Decimal, scale : Int) -> Int {
  let mut v = match parse_uint(d.int_part) {
    Some(x) => x
    None => 0
  }
  let mut i = 0
  while i < scale {
    let digit = if i < d.frac_part.length() {
      match parse_uint(d.frac_part[i:i + 1].to_owned()) {
        Some(x) => x
        None => 0
      }
    } else {
      0
    }
    v = v * 10 + digit
    i = i + 1
  }
  v
}

///|
/// Inverse of `days_from_civil`: turns a day count back into a calendar date.
fn civil_from_days(z : Int64) -> (Int, Int, Int) {
  let zz = z + 719468L
  let era = if zz >= 0L { zz / 146097L } else { (zz - 146096L) / 146097L }
  let doe = zz - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = mp + (if mp < 10L { 3L } else { -9L })
  let year = y + (if m <= 2L { 1L } else { 0L })
  (year.to_int(), m.to_int(), d.to_int())
}

///|
/// Adds a duration's month part to a date, clamping the day to the length of
/// the target month. Adding one month to 31 January gives 28 or 29 February.
fn add_months(year : Int, month : Int, day : Int, months : Int) -> (Int, Int, Int) {
  let total = year * 12 + (month - 1) + months
  let mut ny = total / 12
  let mut nm = total % 12
  if nm < 0 {
    nm = nm + 12
    ny = ny - 1
  }
  let dim = days_in_month(ny, nm + 1)
  let nd = if day > dim { dim } else { day }
  (ny, nm + 1, nd)
}

///|
/// Number of days from 0001-01-01 to the given date, proleptic Gregorian.
/// Negative years are handled by extrapolating the same cycle.
pub fn days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let mut y = year
  if month <= 2 {
    y = y - 1
  }
  let era = if y >= 0 { y / 400 } else { (y - 399) / 400 }
  let yoe = y - era * 400
  let mp = if month > 2 { month - 3 } else { month + 9 }
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe).to_int64() - 719468L
}

///|
/// Total seconds of a temporal value relative to an epoch, ignoring any
/// fractional second. Used for ordering.
///
/// A value with no timezone is ordered as if it were UTC. That is a deliberate
/// simplification: XSD leaves such comparisons implementation-defined.
pub fn temporal_seconds(t : Temporal) -> Int64 {
  let days = days_from_civil(t.year, t.month, t.day)
  let secs = days * 86400L +
    (t.hour * 3600 + t.minute * 60 + t.second).to_int64()
  let offset = match t.tz {
    Some(m) => (m * 60).to_int64()
    None => 0L
  }
  secs - offset
}

///|
/// Compares two temporal values of the same kind.
///
/// Returns None when the ordering is indeterminate. XSD allows that: a value
/// carrying a timezone and one without are not always comparable, because a
/// naive value denotes any instant in a 28-hour window. The rule is
///
///   P < Q  iff  P <  (Q read as +14:00)
///   P > Q  iff  P >  (Q read as -14:00)
///   otherwise indeterminate
///
/// and an indeterminate comparison makes every ordering facet false, so it has
/// to be distinguishable from "equal" rather than folded into zero.
pub fn compare_temporal(a : Temporal, b : Temporal) -> Int? {
  match (a.tz, b.tz) {
    (Some(_), None) => tzoned_vs_naive(a, b)
    (None, Some(_)) =>
      match tzoned_vs_naive(b, a) {
        Some(r) => Some(-r)
        None => None
      }
    _ => Some(compare_on_seconds(a, b))
  }
}

///|
/// `p` carries a timezone, `q` does not. Reading `q` as +14:00 gives the
/// earliest instant it can denote; as -14:00 the latest.
fn tzoned_vs_naive(p : Temporal, q : Temporal) -> Int? {
  let p_secs = temporal_seconds(p)
  let q_secs = temporal_seconds(q)
  let earliest = q_secs - 14L * 3600L
  let latest = q_secs + 14L * 3600L
  if p_secs < earliest {
    Some(-1)
  } else if p_secs > latest {
    Some(1)
  } else {
    None
  }
}

///|
/// Both sides sit on the same timeline, so a plain comparison applies.
fn compare_on_seconds(a : Temporal, b : Temporal) -> Int {
  let sa = temporal_seconds(a)
  let sb = temporal_seconds(b)
  if sa != sb {
    return if sa < sb { -1 } else { 1 }
  }
  // Compare fractional seconds digit by digit, padding the shorter one.
  let fa = a.frac_part
  let fb = b.frac_part
  let n = if fa.length() > fb.length() { fa.length() } else { fb.length() }
  let mut i = 0
  while i < n {
    let ca = if i < fa.length() { code_at_dt(fa, i) } else { 48 }
    let cb = if i < fb.length() { code_at_dt(fb, i) } else { 48 }
    if ca != cb {
      return if ca < cb { -1 } else { 1 }
    }
    i = i + 1
  }
  0
}

