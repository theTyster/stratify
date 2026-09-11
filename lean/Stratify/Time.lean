import Std.Time
import Stratify.Types

/-!
# Time conversion

Two timestamp formats matter, and they are not the same format:

* transcripts and audit logs use ISO-8601 UTC — `2026-09-10T21:54:34.274Z`
* `procStart` in the session registry, and `ps -o lstart=`, use `ctime` —
  `Thu Sep 10 23:42:51 2026`

Everything is converted with Howard Hinnant's `days_from_civil`, which is exact integer
arithmetic over a proleptic Gregorian calendar. No libc, no timezone database, no
`Float`: the conversion is a pure function of its digits, so a given timestamp always
maps to the same epoch second on any machine.

## The `procStart` trap

`procStart` in `~/.claude/sessions/<pid>.json` is rendered in **UTC**, while
`ps -o lstart=` renders in **local time**. On this machine the same process start reads
as `Fri Sep 11 04:42:51 2026` in one and `Thu Sep 10 23:42:51 2026` in the other — a
five-hour gap that looks like a completely different process.

Rather than resolve the local offset (which would need a timezone database, or a shell
out to `date`, and would still be wrong across a DST boundary), `sameInstantModuloTZ`
compares the two as UTC and accepts the difference when it *looks like* a timezone
offset: a whole number of quarter-hours, strictly under a day. Every real UTC offset is
a multiple of 15 minutes and bounded by ±14:00, so this admits exactly the legitimate
readings. See `Sessions.lean` for the residual pid-reuse risk this leaves and how the
command-name check narrows it.
-/

namespace Stratify.Time

/-- Days from the Unix epoch to `y-m-d`, proleptic Gregorian.

Hinnant's `days_from_civil`. `Int` division in Lean truncates toward zero, which is what
the algorithm assumes, and the `y - 399` adjustment keeps it correct for negative years
even though every timestamp we see is well after 1970. -/
def daysFromCivil (y m d : Int) : Int :=
  let y' := if m ≤ 2 then y - 1 else y
  let era := (if y' ≥ 0 then y' else y' - 399) / 400
  let yoe := y' - era * 400
  let mp := if m > 2 then m - 3 else m + 9
  let doy := (153 * mp + 2) / 5 + d - 1
  let doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468

/-- Epoch seconds for a UTC civil date-time. Saturates at `0` for anything before the
epoch, since every timestamp `stratify` handles is after it. -/
def epochOfUtc (y m d h mi s : Int) : Epoch :=
  let v := daysFromCivil y m d * 86400 + h * 3600 + mi * 60 + s
  if v ≤ 0 then 0 else v.toNat

/-! ## Parsing -/

/-- Split a character list on a separator, keeping empty fields.

Hand-rolled over `List Char` rather than using `String.split`: that returns a
`Std.Iter` as of Lean 4.31 and has changed shape across recent toolchains. These
strings are timestamps, so the cost is irrelevant and the stability is worth it. -/
private def splitChars (sep : Char) : List Char → List Char → List String
  | [], acc => [String.ofList acc.reverse]
  | c :: cs, acc =>
    if c == sep then String.ofList acc.reverse :: splitChars sep cs []
    else splitChars sep cs (c :: acc)

/-- Split on a character and drop empty fields. `ctime` space-pads single-digit days
(`Wed Sep  9 10:18:13 2026`), which would otherwise yield an empty component. -/
private def splitNonEmpty (sep : Char) (s : String) : List String :=
  (splitChars sep s.toList []).filter (· != "")

/-- Leading run of digits. -/
private def leadingDigits : List Char → List Char
  | [] => []
  | c :: cs => if c.isDigit then c :: leadingDigits cs else []

/-- Leading run of digits as a `Nat`. Stops at the first non-digit, so it reads `34`
out of `34.274Z` without a separate trim. -/
private def leadingNat (s : String) : Option Nat :=
  let ds := leadingDigits s.toList
  if ds.isEmpty then none else (String.ofList ds).toNat?

/-- Three-letter English month abbreviation to month number. -/
def monthOfAbbrev (s : String) : Option Nat :=
  match String.ofList (s.toList.take 3) with
  | "Jan" => some 1  | "Feb" => some 2  | "Mar" => some 3
  | "Apr" => some 4  | "May" => some 5  | "Jun" => some 6
  | "Jul" => some 7  | "Aug" => some 8  | "Sep" => some 9
  | "Oct" => some 10 | "Nov" => some 11 | "Dec" => some 12
  | _ => none

/-- Parse an ISO-8601 UTC timestamp such as `2026-09-10T21:54:34.274Z`.

Fractional seconds are read and discarded: rate-limit windows and sprint cadences are
whole seconds, and carrying milliseconds would only invite a rounding difference between
the two timestamp sources. -/
def parseIso8601 (s : String) : Option Epoch := do
  let parts := splitNonEmpty 'T' s
  match parts with
  | [datePart, timePart] =>
    match splitNonEmpty '-' datePart, splitNonEmpty ':' timePart with
    | [ys, ms, ds], [hs, mis, ss] => do
      let y ← leadingNat ys
      let mo ← leadingNat ms
      let d ← leadingNat ds
      let h ← leadingNat hs
      let mi ← leadingNat mis
      let sec ← leadingNat ss
      pure (epochOfUtc y mo d h mi sec)
    | _, _ => none
  | _ => none

/-- Parse a `ctime`-style timestamp such as `Thu Sep 10 23:42:51 2026`.

The result is the epoch second the timestamp denotes **if read as UTC**. Callers must
not treat it as an absolute instant unless they know the source's zone — see
`sameInstantModuloTZ`. -/
def parseCtimeAsUtc (s : String) : Option Epoch := do
  match splitNonEmpty ' ' s with
  | [_dow, mon, dayS, timeS, yearS] => do
    let mo ← monthOfAbbrev mon
    let d ← leadingNat dayS
    let y ← leadingNat yearS
    match splitNonEmpty ':' timeS with
    | [hs, mis, ss] => do
      let h ← leadingNat hs
      let mi ← leadingNat mis
      let sec ← leadingNat ss
      pure (epochOfUtc y mo d h mi sec)
    | _ => none
  | _ => none

/-- Largest real-world UTC offset, in seconds (`+14:00`, Line Islands). -/
def maxTzOffset : Nat := 14 * 3600

/-- Do two `ctime` readings denote the same instant, allowing for one of them being in
local time and the other in UTC?

Accepts a difference that is a whole number of quarter-hours and strictly within the
real offset range. Every IANA offset is a multiple of 900 seconds and bounded by
±14:00, so a legitimate UTC/local pair always passes and an unrelated process start
essentially never does. -/
def sameInstantModuloTZ (a b : Epoch) : Bool :=
  let diff := if a ≤ b then b - a else a - b
  diff % 900 == 0 && diff ≤ maxTzOffset

/-! ## The clock -/

/-- Wall-clock epoch seconds.

Wall clock, not `IO.monoMsNow`: every timestamp `stratify` compares against — a
rate-limit `resets_at`, a transcript row, a session's `updatedAt` — is absolute, so a
monotonic clock would be meaningless here. -/
def nowEpoch : IO Epoch := do
  let ts ← Std.Time.Timestamp.now
  return ts.toSecondsSinceUnixEpoch.val.toNat

/-! ## Formatting -/

/-- Whole minutes in a second count, rounded down. -/
def toMinutes (seconds : Nat) : Nat := seconds / 60

/-- Render a duration as `2h 14m`, or `47m`, or `38s`. -/
def humanDuration (seconds : Nat) : String :=
  if seconds < 60 then s!"{seconds}s"
  else
    let m := seconds / 60
    if m < 60 then s!"{m}m"
    else s!"{m / 60}h {m % 60}m"

/-! ## Checks

Fixtures cross-checked against timestamps actually present on this machine.

The date arithmetic is pure `Int` and closes by `decide` in the kernel. Anything that
touches a `String` uses `#guard` instead: `String` is a kernel-opaque primitive, so
`decide` cannot reduce it, and `#guard` evaluates compiled code — which is also the
code path the binary itself takes. -/

/-- The epoch itself. -/
example : daysFromCivil 1970 1 1 = 0 := by decide

/-- Leap-day handling, the classic off-by-one in civil date arithmetic. -/
example : daysFromCivil 2000 3 1 = 11017 := by decide

-- A real transcript timestamp: `2026-09-10T21:54:34.274Z`.
#guard parseIso8601 "2026-09-10T21:54:34.274Z" == some 1789077274

-- The same instant without fractional seconds parses identically.
#guard parseIso8601 "2026-09-10T21:54:34Z" == some 1789077274

-- End-of-February, non-leap year.
#guard parseIso8601 "2026-02-28T23:59:59Z" == some 1772323199

-- A real `procStart` value, read as UTC.
#guard parseCtimeAsUtc "Fri Sep 11 04:42:51 2026" == some 1789101771

-- `ctime` space-pads single-digit days; the parser must not trip on it.
#guard parseCtimeAsUtc "Wed Sep  9 10:18:13 2026" == some 1788949093

-- The registry/`ps` pair observed on this machine: `procStart` in UTC against `ps -o
-- lstart=` in local time, five hours apart, recognised as one instant.
#guard
  sameInstantModuloTZ
    (parseCtimeAsUtc "Fri Sep 11 04:42:51 2026").get!
    (parseCtimeAsUtc "Thu Sep 10 23:42:51 2026").get!

-- An unrelated process start is not mistaken for a timezone offset. This is the
-- pid-reuse case: pid 65031 was alive, but with a start time weeks off.
#guard
  !(sameInstantModuloTZ
      (parseCtimeAsUtc "Fri Sep 11 04:42:51 2026").get!
      (parseCtimeAsUtc "Wed Aug 26 17:39:22 2026").get!)

-- A difference that is not a whole quarter-hour is rejected even when small, since no
-- real zone is offset by seconds.
#guard !(sameInstantModuloTZ 1000 1037)

-- Malformed input yields `none` rather than a wrong instant.
#guard parseIso8601 "not-a-timestamp" == none
#guard parseCtimeAsUtc "" == none
#guard monthOfAbbrev "Frobuary" == none

end Stratify.Time
