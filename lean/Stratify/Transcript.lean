import Lean.Data.Json
import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Sessions

/-!
# Per-session token attribution

The statusline reports one global number: how much of the shared window is gone. It
cannot say *who spent it*. That attribution comes from the transcripts, where every
assistant row carries its own `message.usage`.

Attribution is informational rather than load-bearing. Scheduling weights come from
declared niceness, not from measured burn — a session does not get a larger share by
spending more. What attribution buys is the ability to show which sessions are heavy,
and to calibrate tokens against window percentage when a sensor sample exists.

## Cost

The rows we want are a small fraction of a transcript. Most bytes are `attachment` and
tool-result records, sometimes megabytes each. A substring prefilter for
`"type":"assistant"` skips JSON-parsing those entirely, which is the difference between
scanning a 19 MB transcript in milliseconds and in seconds.

Files are further narrowed by mtime before being opened at all: a transcript last
written before the window started cannot contain a row inside it.
-/

namespace Stratify.Transcript

open Lean

/-- Cheap substring test, used to skip rows that cannot be assistant messages. -/
def containsSub (hay needle : String) : Bool :=
  (hay.splitOn needle).length > 1

/-- What a scan of one transcript yields. -/
structure Scan where
  tally : TokenTally := TokenTally.empty
  /-- Model id from the most recent in-window assistant row. -/
  lastModel : String := ""
  /-- Reasoning effort from the most recent in-window assistant row. -/
  lastEffort : String := ""
  /-- Timestamp of the most recent in-window assistant row. -/
  lastActivity : Epoch := 0
  /-- Assistant rows counted. -/
  rows : Nat := 0
  deriving Repr, DecidableEq, Inhabited

/-- Token usage out of one assistant row's `message.usage`. -/
def usageOf (j : Json) : TokenTally :=
  { input := J.nat j ["message", "usage", "input_tokens"]
    output := J.nat j ["message", "usage", "output_tokens"]
    cacheCreation := J.nat j ["message", "usage", "cache_creation_input_tokens"]
    cacheRead := J.nat j ["message", "usage", "cache_read_input_tokens"] }

/-- Fold one record into a scan, if it is an in-window assistant row.

Synthetic rows (`model: "<synthetic>"`) are Claude Code's own injected messages — rate
limit notices and the like. They carry a zeroed usage block and no real model, so
counting them would add a phantom row and clobber `lastModel`. -/
def foldRow (from_ to_ : Epoch) (s : Scan) (line : String) : Scan :=
  if !containsSub line "\"type\":\"assistant\"" then s
  else match J.parseLine line with
    | none => s
    | some j =>
      let model := J.str j ["message", "model"]
      if model == "" || model == "<synthetic>" then s
      else match J.iso? j ["timestamp"] with
        | none => s
        | some ts =>
          if ts < from_ || ts > to_ then s
          else
            let newer := ts ≥ s.lastActivity
            { tally := s.tally + usageOf j
              lastModel := if newer then model else s.lastModel
              lastEffort := if newer then J.str j ["effort"] else s.lastEffort
              lastActivity := if newer then ts else s.lastActivity
              rows := s.rows + 1 }

/-- Scan one transcript for rows inside `[from_, to_]`. -/
def scanFile (path : System.FilePath) (from_ to_ : Epoch) : IO Scan := do
  let lines ← Ndjson.readAll path
  return lines.foldl (foldRow from_ to_) {}

/-- Was this file written at or after `from_`?

An mtime before the window start proves no row inside the window, so the file need not
be opened. This is what keeps a 736 MB transcript corpus from being read every run. -/
def touchedSince (path : System.FilePath) (from_ : Epoch) : IO Bool := do
  try
    let md ← path.metadata
    return decide (md.modified.sec.toNat ≥ from_)
  catch _ => return false

/-- Scan the transcript belonging to one session. -/
def scanSession (r : SessionRec) (from_ to_ : Epoch) : IO Scan := do
  match ← Sessions.transcriptPath r.sessionId r.cwd with
  | none => return {}
  | some p =>
    if !(← touchedSince p from_) then return {}
    scanFile p from_ to_

/-- Attach in-window model, effort and token counts to a session record. -/
def enrich (r : SessionRec) (from_ to_ : Epoch) : IO SessionRec := do
  let s ← scanSession r from_ to_
  return { r with
    model := if s.lastModel == "" then r.model else s.lastModel
    effort := if s.lastEffort == "" then r.effort else s.lastEffort
    tally := s.tally
    lastActivity := max r.lastActivity s.lastActivity }

/-! ## Checks -/

private def assistantRow : String :=
  "{\"type\":\"assistant\",\"timestamp\":\"2026-09-10T21:54:34.274Z\",\"effort\":\"medium\"," ++
  "\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":2," ++
  "\"cache_creation_input_tokens\":81463,\"cache_read_input_tokens\":0,\"output_tokens\":1144}}}"

/-- `2026-09-10T21:54:34Z`. -/
private def rowTs : Epoch := 1789077274

#guard containsSub assistantRow "\"type\":\"assistant\""
#guard !(containsSub "{\"type\":\"attachment\"}" "\"type\":\"assistant\"")

-- A real assistant row, fully decoded.
#guard (foldRow 0 2000000000 {} assistantRow).rows == 1
#guard (foldRow 0 2000000000 {} assistantRow).lastModel == "claude-opus-5"
#guard (foldRow 0 2000000000 {} assistantRow).lastEffort == "medium"
#guard (foldRow 0 2000000000 {} assistantRow).lastActivity == rowTs
#guard (foldRow 0 2000000000 {} assistantRow).tally.output == 1144
#guard (foldRow 0 2000000000 {} assistantRow).tally.cacheCreation == 81463
#guard (foldRow 0 2000000000 {} assistantRow).tally.total == 2 + 81463 + 0 + 1144

-- Rows outside the window contribute nothing. This is the property the whole sliding
-- window depends on, and the reason byte offsets were dropped.
#guard (foldRow (rowTs + 1) 2000000000 {} assistantRow).rows == 0
#guard (foldRow 0 (rowTs - 1) {} assistantRow).rows == 0
#guard (foldRow rowTs rowTs {} assistantRow).rows == 1

-- Non-assistant rows are skipped without being parsed.
#guard (foldRow 0 2000000000 {} "{\"type\":\"attachment\",\"x\":1}").rows == 0
#guard (foldRow 0 2000000000 {} "{\"type\":\"cost-state\"}").rows == 0

-- Claude Code's injected rate-limit notices must not be counted as model turns.
#guard
  (foldRow 0 2000000000 {}
    "{\"type\":\"assistant\",\"timestamp\":\"2026-09-10T21:54:34Z\",\"message\":{\"model\":\"<synthetic>\",\"usage\":{\"output_tokens\":0}}}").rows
    == 0

-- A truncated trailing record is ignored rather than aborting the scan.
#guard (foldRow 0 2000000000 {} "{\"type\":\"assistant\",\"mess").rows == 0

-- Accumulation across rows is additive.
#guard
  ([assistantRow, assistantRow].foldl (foldRow 0 2000000000) {}).tally.output == 2288
#guard ([assistantRow, assistantRow].foldl (foldRow 0 2000000000) {}).rows == 2

end Stratify.Transcript
