import Lean.Data.Json
import Stratify.Types
import Stratify.Json
import Stratify.Paths

/-!
# Append-only NDJSON

The shared state is a log, not a database, and every writer is a separate OS process
started independently by whichever Claude session happens to render its statusline. That
rules out anything needing a lock held across a read-modify-write.

## Why appends are atomic here

POSIX guarantees that a single `write(2)` to a file opened `O_APPEND` is atomic with
respect to other appenders, provided the payload does not exceed `PIPE_BUF` (512 bytes
is the portable floor; macOS and Linux are both higher). So the rule is: one record is
one `write`, and a record that would exceed the bound is refused outright rather than
silently torn in half.

This matters more than it might appear. Claude Code cancels an in-flight statusline
script the moment another update arrives, and it debounces at 300 ms — so `stratify
record` gets killed mid-run routinely. A partial line must be impossible, not unlikely.

## Reading

Transcripts are append-only and chronologically ordered, so a byte offset is a valid
resume point. Lean 4.31's `IO.FS.Handle` has `rewind` but no `seek`, so the skipped
prefix is read and discarded rather than seeked past. That is deliberate rather than
reluctant: the expensive part of ingesting a transcript is JSON-parsing it, not reading
it, and the offset cache still skips all of that. Reading 42 MB — the volume touched
inside a 5-hour window on this machine — costs tens of milliseconds.

A trailing partial line is expected, not exceptional: transcripts are being appended to
while we read them. The offset only ever advances past a complete record.
-/

namespace Stratify.Ndjson

open Lean

/-- Portable atomic-append bound. A record at or under this size is written by one
`write(2)` and cannot interleave with a concurrent appender. -/
def pipeBuf : Nat := 512

/-- Append one record atomically.

Fails rather than writing a record that would exceed `pipeBuf`, because a torn line is
worse than a missing one: a missing sample degrades a estimate, a torn line corrupts
every parse after it. -/
def append (path : System.FilePath) (record : String) : IO Unit := do
  let line := record ++ "\n"
  let bytes := line.toUTF8
  if bytes.size > pipeBuf then
    throw <| IO.userError
      s!"stratify: refusing to append {bytes.size} bytes; atomicity bound is {pipeBuf}"
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  let h ← IO.FS.Handle.mk path IO.FS.Mode.append
  h.write bytes
  h.flush

/-- Index just past the last newline in a byte array, or `0` if there is none. -/
private def lastNewlineEnd (bs : ByteArray) : Nat := Id.run do
  let mut i := bs.size
  while i > 0 do
    if bs[i - 1]! == 0x0A then return i
    i := i - 1
  return 0

/-- Result of an incremental read. -/
structure Tail where
  /-- Complete records only. -/
  lines : Array String
  /-- Resume point: always immediately after a newline. -/
  newOffset : Nat
  deriving Inhabited

/-- Read complete records from `offset` to the end of the file.

Handles the three ways an offset can go stale:
* the file grew — the normal case, read the new suffix;
* the file shrank below the offset (rotated, truncated, replaced) — restart from `0`;
* the file is gone — yield nothing rather than failing the caller's whole run. -/
def readTail (path : System.FilePath) (offset : Nat) : IO Tail := do
  if !(← path.pathExists) then return { lines := #[], newOffset := 0 }
  let size ← try
      pure (← path.metadata).byteSize.toNat
    catch _ => pure 0
  if size == 0 then return { lines := #[], newOffset := 0 }
  -- A file smaller than our resume point was replaced, not appended to.
  let start := if size < offset then 0 else offset
  if start ≥ size then return { lines := #[], newOffset := size }
  let all ← try IO.FS.readBinFile path catch _ => pure ByteArray.empty
  if all.size == 0 then return { lines := #[], newOffset := 0 }
  let slice := all.extract start all.size
  let complete := lastNewlineEnd slice
  if complete == 0 then
    -- A record longer than the remaining file: nothing complete to hand back yet.
    return { lines := #[], newOffset := start }
  let usable := slice.extract 0 complete
  let text := match String.fromUTF8? usable with
    | some s => s
    | none => ""
  let lines := text.splitOn "\n" |>.filter (· != "") |>.toArray
  return { lines := lines, newOffset := start + complete }

/-- Read every complete record in a file. -/
def readAll (path : System.FilePath) : IO (Array String) := do
  return (← readTail path 0).lines

/-! ### On byte offsets and sliding windows

`readTail` takes a resume offset, and an earlier draft cached one per transcript. That
is unsound for the question `stratify` actually asks.

A resume offset is only valid for a *monotone accumulator* — a total that never
un-counts anything. But the budget question is about a **sliding** window: "how much was
spent in the last five hours". Rows that were inside the window on the previous run fall
out of it on this one, and an offset-based reader can never revisit them to subtract
their contribution. It would report a total that only ever grew.

So transcripts are re-scanned each run, narrowed by file mtime to those touched inside
the window — twelve files and 42 MB on this machine, tens of milliseconds. The offset
parameter stays because it is correct for genuinely append-only consumption, which is
what `samples.ndjson` is.

## Sample codec

Short keys, because the encoded record must fit inside `pipeBuf`. A UUID session id is
already 36 bytes and a model id can be 30; verbose keys would push a realistic sample
past the atomicity bound, and the failure mode would be losing samples exactly when the
most sessions are running. -/

/-- Encode a sample as one NDJSON record. -/
def encodeSample (s : Sample) : String :=
  let win (w : Option WindowSample) (uk rk : String) : List (String × Json) :=
    match w with
    | none => []
    | some v => [(uk, Json.num (JsonNumber.fromNat v.used)),
                 (rk, Json.num (JsonNumber.fromNat v.resetsAt))]
  let fields : List (String × Json) :=
    [("t", Json.num (JsonNumber.fromNat s.ts)),
     ("s", Json.str s.sessionId),
     ("m", Json.str s.model)]
    ++ (if s.effort == "" then [] else [("e", Json.str s.effort)])
    ++ win s.fiveHour "u5" "r5"
    ++ win s.sevenDay "u7" "r7"
    ++ win s.spendLimit "us" "rs"
    ++ (if s.ctxInput == 0 then [] else [("ci", Json.num (JsonNumber.fromNat s.ctxInput))])
    ++ (if s.ctxOutput == 0 then [] else [("co", Json.num (JsonNumber.fromNat s.ctxOutput))])
    ++ (if s.costMicroUsd == 0 then [] else
          [("c", Json.num (JsonNumber.fromNat s.costMicroUsd))])
  (Json.mkObj fields).compress

/-- Decode a sample record. -/
def decodeSample (line : String) : Option Sample := do
  let j ← J.parseLine line
  let ts ← J.nat? j ["t"]
  let sid ← J.str? j ["s"]
  let win (uk rk : String) : Option WindowSample :=
    match J.nat? j [uk], J.nat? j [rk] with
    | some u, some r => some { used := u, resetsAt := r }
    | _, _ => none
  pure {
    ts := ts
    sessionId := sid
    model := J.str j ["m"]
    effort := J.str j ["e"]
    fiveHour := win "u5" "r5"
    sevenDay := win "u7" "r7"
    spendLimit := win "us" "rs"
    ctxInput := J.nat j ["ci"]
    ctxOutput := J.nat j ["co"]
    costMicroUsd := J.nat j ["c"] }

/-! ## Checks -/

private def sampleFixture : Sample :=
  { ts := 1789102605
    sessionId := "c9db1741-b3da-45a9-9fba-83736fcd3c37"
    model := "claude-opus-5[1m]"
    effort := "max"
    fiveHour := some { used := 23500, resetsAt := 1789045200 }
    sevenDay := some { used := 58000, resetsAt := 1789178400 }
    spendLimit := none
    ctxInput := 15500
    ctxOutput := 1200
    costMicroUsd := 12340 }

-- A realistic sample round-trips exactly.
#guard decodeSample (encodeSample sampleFixture) == some sampleFixture

-- And, critically, fits inside the atomicity bound with room to spare.
#guard (encodeSample sampleFixture ++ "\n").toUTF8.size < pipeBuf

-- Even with the longest plausible field values it still fits. A session id is a UUID
-- and a model id is bounded; this is the worst case the sensor can actually emit.
#guard
  ((encodeSample
      { sampleFixture with
        model := "claude-opus-5-20260514-preview[1m]"
        effort := "xhigh"
        spendLimit := some { used := 162400, resetsAt := 1790812800 }
        ctxInput := 999999, ctxOutput := 999999, costMicroUsd := 99999999 }) ++ "\n").toUTF8.size
    < pipeBuf

-- Absent windows stay absent rather than decoding as a measured zero, which would be a
-- silent claim that the window is empty.
#guard (decodeSample (encodeSample { sampleFixture with fiveHour := none })).get!.fiveHour == none

-- A sample carries its windows through tagged as measured.
#guard (sampleFixture.windows.map (·.prov)) == [Provenance.measured, Provenance.measured]
#guard (sampleFixture.windows.map (·.kind)) == [WindowKind.fiveHour, WindowKind.sevenDay]

-- Garbage decodes to `none` rather than to a zeroed sample.
#guard decodeSample "not json" == none
#guard decodeSample "{\"t\":1}" == none

end Stratify.Ndjson
