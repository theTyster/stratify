import Lean.Data.Json
import Stratify.Types
import Stratify.Time

/-!
# JSON decoding helpers

Thin, total accessors over `Lean.Json`. Every one returns an `Option` or a caller-
supplied default: `stratify` reads files written by other programs, sometimes while they
are being appended to, and a malformed record must degrade to "unknown" rather than
abort a scheduling decision.

## Percentages stay exact

`JsonNumber` is an `Int` mantissa over a power-of-ten exponent, which means a statusline
reading of `23.5` can be converted to milli-percentage-points by integer arithmetic
alone. Routing it through `Float` first would introduce a representation error that
nothing downstream could detect, and would make the allocator's arithmetic unprovable
for the sake of a conversion that does not need it.

Two scales are in play and they are not interchangeable:

* the statusline payload reports **percent**, `0`–`100` (`used_percentage: 23.5`)
* Cowork `rate_limit_event` reports a **fraction**, `0`–`1` (`utilization: 0.58`)

`0.58` means 0.58 % in the first and 58 % in the second. They get separate converters so
the distinction cannot be lost at a call site.
-/

namespace Stratify.J

open Lean

/-! ## Access -/

/-- Follow a chain of object keys. -/
def path? (j : Json) : List String → Option Json
  | [] => some j
  | k :: ks =>
    match j.getObjVal? k with
    | .ok v => path? v ks
    | .error _ => none

/-- String at a path, or `none`. -/
def str? (j : Json) (ks : List String) : Option String :=
  (path? j ks).bind (fun v => v.getStr?.toOption)

/-- String at a path, or a default. -/
def str (j : Json) (ks : List String) (dflt : String := "") : String :=
  (str? j ks).getD dflt

/-- Natural at a path, or `none`. Rejects negatives rather than wrapping. -/
def nat? (j : Json) (ks : List String) : Option Nat :=
  (path? j ks).bind (fun v => v.getNat?.toOption)

/-- Natural at a path, or a default. -/
def nat (j : Json) (ks : List String) (dflt : Nat := 0) : Nat :=
  (nat? j ks).getD dflt

/-- Boolean at a path, or a default. -/
def bool (j : Json) (ks : List String) (dflt : Bool := false) : Bool :=
  ((path? j ks).bind (fun v => v.getBool?.toOption)).getD dflt

/-- Raw number at a path. -/
def num? (j : Json) (ks : List String) : Option JsonNumber :=
  (path? j ks).bind (fun v => v.getNum?.toOption)

/-- Array at a path. -/
def arr? (j : Json) (ks : List String) : Option (Array Json) :=
  (path? j ks).bind (fun v => v.getArr?.toOption)

/-! ## Exact fixed-point conversion -/

/-- Scale a `JsonNumber` by `k` and round half-up, exactly.

`value = mantissa / 10^exponent`, so `value * k = mantissa * k / 10^exponent`. All
integer, no `Float`. Negative results saturate to `0` — every quantity this is used for
(a utilisation, a cost) is non-negative, and a negative reading means a corrupt record,
not a credit. -/
def scaleRound (n : JsonNumber) (k : Nat) : Nat :=
  let scaled : Int := n.mantissa * (k : Int)
  let denom : Int := (10 : Int) ^ n.exponent
  let q : Int := (scaled + denom / 2) / denom
  if q ≤ 0 then 0 else q.toNat

/-- A **percent** reading (`0`–`100`) as milli-percentage-points. Use for the statusline
payload's `used_percentage`. -/
def pctToMpp (n : JsonNumber) : Mpp := scaleRound n 1000

/-- A **fraction** reading (`0`–`1`) as milli-percentage-points. Use for Cowork's
`rate_limit_event` `utilization`. -/
def fracToMpp (n : JsonNumber) : Mpp := scaleRound n 100000

/-- Percent at a path, as `Mpp`. -/
def pct? (j : Json) (ks : List String) : Option Mpp :=
  (num? j ks).map pctToMpp

/-- Fraction at a path, as `Mpp`. -/
def frac? (j : Json) (ks : List String) : Option Mpp :=
  (num? j ks).map fracToMpp

/-- A US-dollar amount as micro-dollars, exactly. -/
def usdToMicro (n : JsonNumber) : Nat := scaleRound n 1000000

/-! ## Timestamps -/

/-- An ISO-8601 `timestamp` field as epoch seconds. -/
def iso? (j : Json) (ks : List String) : Option Epoch :=
  (str? j ks).bind Time.parseIso8601

/-! ## Parsing whole records -/

/-- Parse one line of NDJSON, yielding `none` on anything malformed.

A truncated final line is normal: transcripts are appended to while we read them. -/
def parseLine (line : String) : Option Json :=
  (Json.parse line).toOption

/-! ## Checks -/

-- `23.5 %` is exactly 23 500 mpp, with no floating-point drift.
#guard pctToMpp ⟨235, 1⟩ == 23500

-- An integral percentage.
#guard pctToMpp ⟨41, 0⟩ == 41000

-- Cowork's `utilization: 0.58` is 58 %, not 0.58 %.
#guard fracToMpp ⟨58, 2⟩ == 58000

-- The same digits on the two scales must not agree — this is the bug the split
-- converters exist to prevent.
#guard pctToMpp ⟨58, 2⟩ != fracToMpp ⟨58, 2⟩

-- A full window.
#guard pctToMpp ⟨100, 0⟩ == fullWindow

-- Rounding is half-up at the representable limit.
#guard pctToMpp ⟨2350500, 5⟩ == 23505

-- Spend limits may exceed 100 %; nothing clamps them.
#guard pctToMpp ⟨1624, 1⟩ == 162400

-- A corrupt negative reading saturates rather than wrapping around `Nat`.
#guard pctToMpp ⟨-5, 0⟩ == 0

-- Real statusline shape, decoded end to end.
#guard
  (parseLine "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1738425600}}}"
    |>.bind (fun j => pct? j ["rate_limits", "five_hour", "used_percentage"]))
    == some 23500

#guard
  (parseLine "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":1738425600}}}"
    |>.bind (fun j => nat? j ["rate_limits", "five_hour", "resets_at"]))
    == some 1738425600

-- A real assistant row's nested usage.
#guard
  (parseLine "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"output_tokens\":1144}}}"
    |>.bind (fun j => str? j ["message", "model"]))
    == some "claude-opus-5"

-- A missing path is `none`, not a crash or a zero masquerading as data.
#guard (parseLine "{\"a\":1}" |>.bind (fun j => nat? j ["b", "c"])) == none

-- A truncated line — the normal case when reading a transcript mid-append.
#guard parseLine "{\"type\":\"assis" == none

end Stratify.J
