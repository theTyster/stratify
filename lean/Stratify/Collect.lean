import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Sessions
import Stratify.Transcript
import Stratify.Cowork
import Stratify.Account
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

## Freshness is per window, not per sample

A sample is not a snapshot of every window. Claude Code drops each window from the
payload independently as its `resets_at` passes, so a later sample carrying only
`seven_day` says nothing at all about `five_hour` — it is silence, not a reading of
zero. Selecting the newest *sample* and taking its window list therefore lets a
partial sample erase a perfectly good reading of the other window.

That is not hypothetical either. In this account's log the last `u5` was written at
`t=1789160999` against `r5=1789161000`, and the last `u7` at `t=1789178387` against
`r7=1789178400`: each window vanished from the payload within seconds of its own
reset, and the samples in between are partial. So readings are folded **per
`WindowKind`**, each keeping its own observation time.
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
  /-- Window readings that may be scheduled against. Expired readings are not here;
  see `unknown` for the kinds they described. -/
  windows : List Window
  /-- Kinds we have a reading for that is no longer evidence about the current window,
  paired with that last reading. Reported, never planned against. -/
  unknown : List Window
  /-- Provenance of the window readings, pessimistically combined. -/
  prov : Provenance
  /-- Age of the freshest usable window reading, in seconds. `0` when unknown. -/
  readingAge : Nat
  /-- Whether the statusline shim is present in `settings.json`. -/
  sensorInstalled : Bool
  /-- Whether any session has written a sample recently enough for the sensor to be
  considered running. Distinct from `sensorInstalled`: a healthy sensor reporting a
  payload with no `rate_limits` is live but yields no windows. -/
  sensorLive : Bool
  /-- Age of the newest sample of any kind, windows or not. `0` when there are none. -/
  sensorAge : Nat
  /-- The newest reading of each kind *per account*, before judging. `""` marks readings
  whose account is not known; they belong to every account's view, as all readings did
  before accounts were tracked. `windows`/`unknown` above are the unscoped view. -/
  readings : List (String × Window) := []
  /-- Account key to label, for every account seen. -/
  labels : List (String × String) := []
  deriving Inhabited

/-! ## Folding readings per window kind -/

/-- The newest reading seen for each window kind. -/
structure WindowView where
  fiveHour : Option Window := none
  sevenDay : Option Window := none
  spendLimit : Option Window := none
  deriving Repr, Inhabited

/-- Keep `w` if it is newer than what we hold for its kind. Ties go to `w`, matching
the append-only log's "later line wins" convention. -/
def WindowView.bump (v : WindowView) (w : Window) : WindowView :=
  let newer (o : Option Window) : Option Window :=
    match o with
    | some prev => if w.observedAt ≥ prev.observedAt then some w else some prev
    | none => some w
  match w.kind with
  | .fiveHour => { v with fiveHour := newer v.fiveHour }
  | .sevenDay => { v with sevenDay := newer v.sevenDay }
  | .spendLimit => { v with spendLimit := newer v.spendLimit }

def WindowView.ofList (ws : List Window) : WindowView :=
  ws.foldl WindowView.bump {}

/-- In a stable order, so output does not depend on log order. -/
def WindowView.toList (v : WindowView) : List Window :=
  v.fiveHour.toList ++ v.sevenDay.toList ++ v.spendLimit.toList

/-- Newest sample timestamp, and the newest reading of each kind per account. -/
structure SampleView where
  /-- Keyed by account key, `""` when the sample's session has no known account. -/
  windows : Std.HashMap String WindowView := {}
  /-- Newest sample of any kind, including one carrying no window at all. That is the
  sensor's heartbeat: it distinguishes "no shim installed" from "shim installed and
  running, payload carries no `rate_limits`". -/
  newestTs : Epoch := 0
  deriving Inhabited

/-- Read the sensor log, attributing each sample through `accountOf`. -/
def loadSamples (accountOf : String → String) : IO SampleView := do
  let path ← Paths.samplesFile
  let lines ← Ndjson.readAll path
  let mut view : SampleView := {}
  for line in lines do
    if let some s := Ndjson.decodeSample line then
      let k := accountOf s.sessionId
      let prev := view.windows.getD k {}
      view := { windows := view.windows.insert k (s.windows.foldl WindowView.bump prev)
                newestTs := max view.newestTs s.ts }
  return view

/-- Window readings judged against the clock: what may be scheduled against, what may
not, and how fresh and how trustworthy the usable ones are. -/
structure Judged where
  windows : List Window
  unknown : List Window
  prov : Provenance
  readingAge : Nat

def judge (g : Guards) (now : Epoch) (all : List Window) : Judged :=
  -- Each reading is judged against the window it actually describes, not against a
  -- single snapshot-wide age. An expired reading is dropped rather than downgraded:
  -- there is no honest number to report for a window whose replacement we have never
  -- seen, and reporting the old one is what let a 97%-consumed window read as empty.
  let stamp := fun (w : Window) =>
    { w with prov := w.provAt g.staleAfter g.rolloverGrace now }
  let windows := (all.filter (fun w => w.usable g.rolloverGrace now)).map stamp
  let unknown := (all.filter (fun w => !w.usable g.rolloverGrace now)).map stamp
  -- Freshest usable reading, which is what the header age refers to.
  let age := match windows with
    | [] => 0
    | w :: rest => rest.foldl (fun a x => min a (now - x.observedAt)) (now - w.observedAt)
  let prov := match windows with
    | [] => Provenance.unknown
    | w :: rest => rest.foldl (fun a x => Provenance.worst a x.prov) w.prov
  { windows := windows, unknown := unknown, prov := prov, readingAge := age }

/-- Fold readings to the newest of each kind, then judge them. -/
def judgeReadings (g : Guards) (now : Epoch) (rs : List (String × Window)) : Judged :=
  judge g now (WindowView.ofList (rs.map (·.2))).toList

/-- Is the statusline shim installed?

Read from `settings.json` rather than inferred from whether a reading happens to be
fresh. Those are different questions, and conflating them told the agent to ask the
user to install a sensor that was already installed and working. -/
def sensorInstalled : IO Bool := do
  let p ← Paths.settingsFile
  if !(← p.pathExists) then return false
  let txt ← try IO.FS.readFile p catch _ => pure ""
  match J.parseLine txt with
  | none => return false
  | some j =>
    let cmd := J.str j ["statusLine", "command"]
    return (cmd.splitOn "stratify").length > 1

/-- Take a full snapshot.

`horizon` selects the window used for token attribution — five hours by default.
Sessions are enriched from their transcripts, which is the expensive step, so only
sessions that are actually claimants get scanned. -/
def snapshot (g : Guards := Guards.default) (horizon : WindowKind := .fiveHour) :
    IO Snapshot := do
  let now ← Time.nowEpoch
  let from_ := now - horizon.nominalSeconds
  -- CLI sessions: registry, then liveness, then transcript enrichment.
  let cli ← Sessions.loadCli
  let live := cli.filter (·.alive)
  let mut enriched : Array SessionRec := #[]
  for r in live do
    let r ← Transcript.enrich r from_ now
    enriched := enriched.push { r with account := ← Account.ofPid r.pid }
  -- Cowork sessions.
  let cowork ← Cowork.load now from_ now
  let coworkLive := cowork.filter (·.session.alive)
  for c in coworkLive do
    enriched := enriched.push c.session
  -- Accounts: what live sessions say now, over what was remembered about them.
  let remembered ← Account.loadMap
  let seen : Array (String × Account) :=
    enriched.filterMap fun r => r.account.map (r.sessionId, ·)
  Account.remember now remembered seen
  let accounts := seen.foldl (fun m (sid, a) => m.insert sid a) remembered
  let accountOf := fun sid => ((accounts.get? sid).map (·.key)).getD ""
  -- Window state, best source first. Readings are folded per kind, not per sample:
  -- a sample carrying only `seven_day` is silence about `five_hour`, not a zero.
  let samples ← loadSamples accountOf
  -- Cowork readings fill kinds the statusline has never covered, and lose to it
  -- wherever both have one — `WindowView.bump` keeps whichever was observed later.
  let coworkReadings : List (String × Window) :=
    cowork.foldl (init := []) fun acc (c : Cowork.CoworkSession) =>
      acc ++ c.windows.map (((c.session.account.map (·.key)).getD ""), ·)
  let readings : List (String × Window) :=
    samples.windows.toList.flatMap (fun (k, v) => v.toList.map (k, ·)) ++ coworkReadings
  let j := judgeReadings g now readings
  let labels : List (String × String) :=
    (accounts.toList.map (fun (_, a) => (a.key, a.label))
      ++ (cowork.filterMap (fun c => c.session.account.map fun a => (a.key, a.label))).toList)
  let installed ← sensorInstalled
  let sensorAge := if samples.newestTs == 0 then 0 else now - samples.newestTs
  let sensorLive := samples.newestTs != 0 && sensorAge ≤ g.sensorLiveWithin
  return { now := now, from_ := from_, sessions := enriched
           windows := j.windows, unknown := j.unknown, prov := j.prov, readingAge := j.readingAge
           sensorInstalled := installed, sensorLive := sensorLive, sensorAge := sensorAge
           readings := readings, labels := labels }

/-! ## Derived views -/

/-- Label for an account key, if it has one. -/
def Snapshot.labelOf (s : Snapshot) (key : String) : Option String :=
  (s.labels.find? (·.1 == key)).map (·.2)

/-- Whether any account is known at all. When none is, every view is the unscoped one,
exactly as before accounts were tracked. -/
def Snapshot.anyAccount (s : Snapshot) : Bool :=
  s.sessions.any (·.account.isSome) || s.readings.any (·.1 != "")

/-- The snapshot as one account sees it: its own sessions and readings, plus every
session and reading whose account is not known. Those stay in on purpose — dropping a
claimant on a guess would hand out window that may already be spoken for. -/
def Snapshot.scope (g : Guards) (s : Snapshot) (key : String) : Snapshot :=
  let sessions := s.sessions.filter fun r =>
    match r.account with
    | none => true
    | some a => a.key == key
  let j := judgeReadings g s.now (s.readings.filter fun (k, _) => k == "" || k == key)
  { s with sessions := sessions, windows := j.windows, unknown := j.unknown
           prov := j.prov, readingAge := j.readingAge }

/-- Total tokens attributed inside the window. -/
def totalTokens (s : Snapshot) : Tokens :=
  s.sessions.foldl (fun a r => a + r.tally.total) 0

/-- Claimant weights, in registry order. -/
def weights (s : Snapshot) (priorityOf : String → Priority) : List Milli :=
  (s.sessions.map (fun r => weightOf (priorityOf r.sessionId))).toList

end Stratify.Collect
