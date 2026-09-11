import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Sessions
import Stratify.Transcript
import Stratify.Cowork
import Stratify.Allocate

/-!
# Assembling the picture

Pulls the four sources together into one `Snapshot`: the session registry, the
transcripts, the Cowork store, and the sensor log.

## Where window state comes from, in order of preference

1. **The newest statusline sample.** Measured, seconds old, and account-wide — any
   session's sample describes the same shared window, so the newest one wins regardless
   of which session wrote it.
2. **The newest Cowork `rate_limit_event`.** Also measured, but emitted only when a
   warning threshold is crossed, so it can be hours or days stale. Better than nothing,
   and its age is reported.
3. **Nothing.** Provenance `unknown`. The tool says so rather than inventing a number.

That third case is not a hypothetical: it is what every machine looks like until the
statusline shim is installed.
-/

namespace Stratify.Collect

open Lean

/-- Everything one run needs to make a decision. -/
structure Snapshot where
  now : Epoch
  /-- Start of the window under consideration, for token attribution. -/
  from_ : Epoch
  /-- Claimants: live CLI sessions plus active Cowork sessions. -/
  sessions : Array SessionRec
  /-- Best available window readings. -/
  windows : List Window
  /-- Provenance of the window readings. -/
  prov : Provenance
  /-- Age of the window readings, in seconds. `0` when unknown. -/
  readingAge : Nat
  deriving Inhabited

/-- Latest sample per session, plus the newest sample overall. -/
structure SampleView where
  bySession : Std.HashMap String Sample := {}
  newest : Option Sample := none
  deriving Inhabited

/-- Read the sensor log. -/
def loadSamples : IO SampleView := do
  let path ← Paths.samplesFile
  let lines ← Ndjson.readAll path
  let mut view : SampleView := {}
  for line in lines do
    if let some s := Ndjson.decodeSample line then
      -- Keep the newest reading per session, and the newest overall.
      match view.bySession.get? s.sessionId with
      | some prev => if s.ts ≥ prev.ts then view := { view with bySession := view.bySession.insert s.sessionId s }
      | none => view := { view with bySession := view.bySession.insert s.sessionId s }
      match view.newest with
      | some n => if s.ts ≥ n.ts then view := { view with newest := some s }
      | none => view := { view with newest := some s }
  return view

/-- Take a full snapshot.

`windowKind` selects the horizon used for token attribution — five hours by default.
Sessions are enriched from their transcripts, which is the expensive step, so only
sessions that are actually claimants get scanned. -/
def snapshot (horizon : WindowKind := .fiveHour) : IO Snapshot := do
  let now ← Time.nowEpoch
  let from_ := now - horizon.nominalSeconds
  -- CLI sessions: registry, then liveness, then transcript enrichment.
  let cli ← Sessions.loadCli
  let live := cli.filter (·.alive)
  let mut enriched : Array SessionRec := #[]
  for r in live do
    enriched := enriched.push (← Transcript.enrich r from_ now)
  -- Cowork sessions.
  let cowork ← Cowork.load now from_ now
  let coworkLive := cowork.filter (·.session.alive)
  for c in coworkLive do
    enriched := enriched.push c.session
  -- Window state, best source first.
  let samples ← loadSamples
  let (windows, age) :=
    match samples.newest with
    | some s => (s.windows, now - s.ts)
    | none =>
      -- Newest Cowork reading, by observation time. Taking the last session's
      -- windows instead would pick an arbitrary one, which on this machine meant a
      -- fifteen-day-old record beating a recent one.
      let best : List Window × Epoch :=
        cowork.foldl (init := ([], 0)) fun (acc, accAt) (c : Cowork.CoworkSession) =>
          let obsAt := c.windows.foldl (fun a (w : Window) => max a w.observedAt) 0
          if c.windows.isEmpty || obsAt ≤ accAt then (acc, accAt) else (c.windows, obsAt)
      match best with
      | ([], _) => ([], 0)
      | (ws, obsAt) => (ws, now - obsAt)
  -- A reading older than the shortest window it describes is no longer an observation
  -- of the current window — the window has since reset and we are inferring, not
  -- measuring. Saying "measured" of a 358-hour-old record would be a false claim.
  let prov :=
    if windows.isEmpty then Provenance.unknown
    else if age > WindowKind.fiveHour.nominalSeconds then Provenance.estimated
    else Provenance.measured
  return { now := now, from_ := from_, sessions := enriched
           windows := windows, prov := prov, readingAge := age }

/-! ## Derived views -/

/-- Total tokens attributed inside the window. -/
def totalTokens (s : Snapshot) : Tokens :=
  s.sessions.foldl (fun a r => a + r.tally.total) 0

/-- Claimant weights, in registry order. -/
def weights (s : Snapshot) (priorityOf : String → Priority) : List Milli :=
  (s.sessions.map (fun r => weightOf (priorityOf r.sessionId))).toList

/-- The binding window for this snapshot. -/
def binding (s : Snapshot) (g : Guards) : Window :=
  bindingWindow g s.now s.windows

end Stratify.Collect
