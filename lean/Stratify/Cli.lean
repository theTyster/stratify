import Lean.Data.Json
import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Sessions
import Stratify.Transcript
import Stratify.Cowork
import Stratify.Allocate
import Stratify.Collect

/-!
# Command-line surface

Four commands: `record` (the sensor), `status` (what is happening), `plan` (what this
session should do about it), and `gc` (keep the log bounded).

## `record` runs on the statusline hot path

It is invoked on every statusline render, in every session, and Claude Code kills it
mid-run whenever a newer update arrives. Three consequences shape it:

* **It must never break the pipe.** Whatever happens, stdin is copied to stdout
  unchanged, so the user's real statusline script still renders. A `stratify` bug must
  degrade the sensor, never the status line.
* **It must never fail.** Every error is swallowed. A lost sample costs a little
  calibration accuracy; a non-zero exit would surface as a broken status line.
* **It must write atomically.** See `Ndjson.append`.
-/

namespace Stratify.Cli

open Lean

/-! ## Formatting -/

/-- `Mpp` as a percentage with one decimal, e.g. `23.5%`. -/
def fmtPct (m : Mpp) : String :=
  let whole := m / 1000
  let tenth := (m % 1000) / 100
  s!"{whole}.{tenth}%"

/-- A token count as `1.2M` / `43.1k` / `812`. -/
def fmtTokens (t : Tokens) : String :=
  if t ≥ 1000000 then s!"{t / 1000000}.{(t % 1000000) / 100000}M"
  else if t ≥ 1000 then s!"{t / 1000}.{(t % 1000) / 100}k"
  else toString t

/-- First `n` characters. `String.take` yields a `String.Slice` as of Lean 4.31; going
through `List Char` keeps the type stable across toolchains. -/
def takeN (s : String) (n : Nat) : String := String.ofList (s.toList.take n)

/-- All but the first `n` characters. -/
def dropN (s : String) (n : Nat) : String := String.ofList (s.toList.drop n)

/-- Pad or truncate to an exact width, so columns line up. -/
def pad (s : String) (w : Nat) : String :=
  let cs := s.toList
  if cs.length ≥ w then String.ofList (cs.take w)
  else s ++ String.ofList (List.replicate (w - cs.length) ' ')

/-- Replace a `$HOME` prefix with `~`. -/
def tildify (home path : String) : String :=
  if home != "" && path.startsWith home then "~" ++ dropN path home.length else path

/-- How a provenance should be described to a human. -/
def provLabel : Provenance → String
  | .measured => "measured"
  | .estimated => "estimated"
  | .unknown => "UNKNOWN"

/-! ## The sensor -/

/-- Build a sample from a statusline payload. -/
def sampleOfStatusline (j : Json) (now : Epoch) : Option Sample := do
  let sid ← J.str? j ["session_id"]
  let win (k : WindowKind) : Option WindowSample :=
    match J.pct? j ["rate_limits", k.key, "used_percentage"],
          J.nat? j ["rate_limits", k.key, "resets_at"] with
    | some u, some r => some { used := u, resetsAt := r }
    | _, _ => none
  pure {
    ts := now
    sessionId := sid
    model := J.str j ["model", "id"]
    effort := J.str j ["effort", "level"]
    fiveHour := win .fiveHour
    sevenDay := win .sevenDay
    spendLimit := win .spendLimit
    ctxInput := J.nat j ["context_window", "total_input_tokens"]
    ctxOutput := J.nat j ["context_window", "total_output_tokens"]
    costMicroUsd :=
      match J.num? j ["cost", "total_cost_usd"] with
      | some n => J.usdToMicro n
      | none => 0 }

/-- `stratify record` — read a statusline payload, log it, pass it through.

Nothing here is allowed to fail or to alter the payload. -/
def record : IO UInt32 := do
  let input ← try (← IO.getStdin).readToEnd catch _ => pure ""
  -- Pass through first: if anything below throws, the status line has already been fed.
  IO.print input
  (← IO.getStdout).flush
  try
    if let some j := J.parseLine input then
      let now ← Time.nowEpoch
      if let some s := sampleOfStatusline j now then
        -- A sample with no window reading teaches us nothing and still costs a line.
        if s.fiveHour.isSome || s.sevenDay.isSome || s.spendLimit.isSome then
          Ndjson.append (← Paths.samplesFile) (Ndjson.encodeSample s)
  catch _ => pure ()
  return 0

/-! ## status -/

/-- Render one window line. -/
def windowLine (w : Window) (now : Epoch) : String :=
  let name := match w.kind with
    | .fiveHour => "5h "
    | .sevenDay => "7d "
    | .spendLimit => "spend"
  if w.rolledOver now then
    s!"  {name}  {pad (fmtPct w.used) 8} (window has reset; reading is stale)"
  else
    s!"  {name}  {pad (fmtPct w.used) 8} resets in {Time.humanDuration (w.secondsLeft now)}"

/-- The human-readable report. -/
def renderStatus (s : Collect.Snapshot) (home : String) : String := Id.run do
  let mut out := ""
  if s.windows.isEmpty then
    out := out ++ "Rate-limit windows: UNKNOWN — no sensor data.\n\n"
    out := out ++ "  `used %` and `resets_at` are not persisted anywhere on disk; they exist\n"
    out := out ++ "  only in the statusline payload. Until the sensor is installed, session\n"
    out := out ++ "  counts and token attribution below are real, but window state is not\n"
    out := out ++ "  available at all. Install with:\n\n"
    out := out ++ "    stratify install-sensor\n\n"
  else
    out := out ++ s!"Rate-limit windows  [{provLabel s.prov}"
    out := out ++ (if s.readingAge > 0 then s!", {Time.humanDuration s.readingAge} old]\n" else "]\n")
    for w in s.windows do
      out := out ++ windowLine w s.now ++ "\n"
    out := out ++ "\n"
  let cliN := (s.sessions.filter (·.origin == .cli)).size
  let coN := (s.sessions.filter (·.origin == .cowork)).size
  out := out ++ s!"Claimants: {s.sessions.size}  ({cliN} cli, {coN} cowork)\n\n"
  out := out ++ "  " ++ pad "SESSION" 28 ++ pad "MODEL" 26 ++ pad "STATUS" 9
             ++ pad "TOKENS/5h" 11 ++ "CWD\n"
  for r in s.sessions do
    let nm := if r.name == "" then takeN r.sessionId 12 else r.name
    out := out ++ "  " ++ pad nm 28 ++ pad r.model 26
               ++ pad r.status.toString 9
               ++ pad (fmtTokens r.tally.total) 11
               ++ tildify home r.cwd ++ "\n"
  out := out ++ s!"\nTotal attributed in window: {fmtTokens (Collect.totalTokens s)} tokens\n"
  return out

/-- The machine-readable report. Field names are stable; this is what the skill reads. -/
def statusJson (s : Collect.Snapshot) : Json :=
  let winJson (w : Window) : Json :=
    Json.mkObj
      [("window", Json.str w.kind.key),
       ("used_mpp", Json.num (JsonNumber.fromNat w.used)),
       ("used_percentage", Json.str (fmtPct w.used)),
       ("resets_at", Json.num (JsonNumber.fromNat w.resetsAt)),
       ("seconds_left", Json.num (JsonNumber.fromNat (w.secondsLeft s.now))),
       ("minutes_left", Json.num (JsonNumber.fromNat (Time.toMinutes (w.secondsLeft s.now)))),
       ("rolled_over", Json.bool (w.rolledOver s.now)),
       ("provenance", Json.str (provLabel w.prov))]
  let sessJson (r : SessionRec) : Json :=
    Json.mkObj
      [("session_id", Json.str r.sessionId),
       ("origin", Json.str r.origin.toString),
       ("pid", Json.num (JsonNumber.fromNat r.pid)),
       ("name", Json.str r.name),
       ("model", Json.str r.model),
       ("effort", Json.str r.effort),
       ("status", Json.str r.status.toString),
       ("cwd", Json.str r.cwd),
       ("tokens_in_window", Json.num (JsonNumber.fromNat r.tally.total)),
       ("last_activity", Json.num (JsonNumber.fromNat r.lastActivity))]
  Json.mkObj
    [("now", Json.num (JsonNumber.fromNat s.now)),
     ("window_from", Json.num (JsonNumber.fromNat s.from_)),
     ("provenance", Json.str (provLabel s.prov)),
     ("reading_age_seconds", Json.num (JsonNumber.fromNat s.readingAge)),
     ("sensor_installed", Json.bool (s.prov.isMeasured)),
     ("claimants", Json.num (JsonNumber.fromNat s.sessions.size)),
     ("windows", Json.arr (s.windows.map winJson).toArray),
     ("sessions", Json.arr (s.sessions.map sessJson)),
     ("total_tokens_in_window", Json.num (JsonNumber.fromNat (Collect.totalTokens s)))]

def status (asJson : Bool) : IO UInt32 := do
  let snap ← Collect.snapshot
  if asJson then
    IO.println (statusJson snap).pretty
  else
    let home := (← IO.getEnv "HOME").getD ""
    IO.print (renderStatus snap home)
  return 0

/-! ## Help -/

def usage : String :=
  "stratify — stratify token spend across concurrent Claude sessions

USAGE
  stratify record                      Sensor. Reads a statusline payload on stdin,
                                       logs the window reading, echoes stdin to stdout.
                                       Chain it ahead of your real statusline script.
  stratify status [--json]             Live sessions, their models, window usage and
                                       time remaining.
  stratify plan --session <id> [--nice N]
                                       This session's share and the interval to wait
                                       between sprints.
  stratify gc [--days N]               Drop log records older than N days (default 8).
  stratify install-sensor              Print the settings.json change that installs the
                                       statusline sensor. Does not modify anything.

NOTES
  Window usage and reset times are not stored on disk by Claude Code; they appear only
  in the statusline payload. Without the sensor, `status` reports sessions and token
  attribution but cannot report window state at all.

  STRATIFY_HOME overrides the runtime-state directory (default ~/.claude/stratify).
"

def installSensor : IO UInt32 := do
  IO.println "Add to ~/.claude/settings.json, preserving your existing statusline script:
"
  IO.println "  \"statusLine\": {
    \"type\": \"command\",
    \"command\": \"stratify record | bash $HOME/.claude/statusline-command.sh\",
    \"refreshInterval\": 15
  }
"
  IO.println "`refreshInterval` matters: statusline events stop firing while a session is
idle, and a session that stops reporting looks like one that stopped spending.

`stratify record` copies stdin to stdout unchanged, so your status line renders
exactly as it does now."
  return 0

/-! ## Argument handling -/

/-- Value of a `--flag value` pair. -/
def flagValue (args : List String) (flag : String) : Option String :=
  match args with
  | [] => none
  | a :: rest => if a == flag then rest.head? else flagValue rest flag

def hasFlag (args : List String) (flag : String) : Bool :=
  args.any (· == flag)

end Stratify.Cli
