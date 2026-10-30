import Lean.Data.Json
import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Account

/-!
# Cowork sessions

Cowork keeps its own store, entirely separate from the CLI's:

```
~/Library/Application Support/Claude/local-agent-mode-sessions/
  <accountUuid>/<orgUuid>/
    local_<uuid>.json      session metadata: model, cwd, cliSessionId, lastActivityAt
    local_<uuid>/
      audit.jsonl          the transcript, with usage and rate-limit records
```

These sessions are **not** mirrored into `~/.claude/projects/`, so a tool that reads
only the CLI's transcripts misses them completely — while they spend from the same
shared window.

## A second measured sensor

`audit.jsonl` carries `rate_limit_event` records, and they are the only measured window
state that Claude Code persists to disk anywhere:

```json
{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{
   "five_hour":{"utilization":0,"resetsAt":1789045200},
   "seven_day":{"utilization":0.58,"resetsAt":1789178400}}}}
```

They only appear when a warning threshold is crossed, so they are sparse and often
stale — useless as a primary sensor, valuable as a cross-check on the statusline and as
a fallback before the statusline shim has been installed.

Note the scale: `utilization` here is a **fraction** (`0.58` means 58 %), whereas the
statusline's `used_percentage` is a percentage (`58.0` means 58 %). `J.fracToMpp` and
`J.pctToMpp` keep them apart.

## Liveness

Cowork sessions have no pid, so there is no equivalent of the registry's process check.
Recency of `lastActivityAt` is the only available signal, and it is a heuristic: a
session idle for twenty minutes may be finished or may be waiting on a human. Treating
a finished session as a claimant costs a slightly smaller share for everyone, which is
the safe direction.
-/

namespace Stratify.Cowork

open Lean

/-- How recently a Cowork session must have acted to count as a claimant. -/
def activeWithin : Nat := 15 * 60

/-- Metadata plus whatever the audit log yielded. -/
structure CoworkSession where
  session : SessionRec
  /-- The CLI session id this Cowork session drives, when it has one. -/
  cliSessionId : String
  /-- Windows from the newest `rate_limit_event`, if any. -/
  windows : List Window
  deriving Repr, Inhabited

/-- Parse a `local_<uuid>.json`. -/
def parseMeta (txt : String) (now : Epoch) : Option (SessionRec × String × Bool) := do
  let j ← J.parseLine txt
  let sid ← J.str? j ["sessionId"]
  let lastMs := J.nat j ["lastActivityAt"]
  let last := lastMs / 1000
  let archived := J.bool j ["isArchived"]
  let sess : SessionRec :=
    { origin := .cowork
      pid := 0
      sessionId := sid
      cwd := J.str j ["cwd"]
      name := J.str j ["title"]
      -- Cowork exposes no busy/idle signal; recency is all there is.
      status := if !archived && now ≤ last + activeWithin then .busy else .idle
      procStart := ""
      version := ""
      model := J.str j ["model"]
      effort := ""
      alive := !archived && now ≤ last + activeWithin
      tally := TokenTally.empty
      lastActivity := last }
  pure (sess, J.str j ["cliSessionId"], archived)

/-- Windows out of one `rate_limit_event` record.

Only windows carrying both a utilisation and a reset time are emitted: a reset time
without a reading, or the reverse, is not something to schedule against. -/
def windowsOfRateLimitEvent (j : Json) (observedAt : Epoch) : List Window :=
  let base := ["rate_limit_info", "unifiedWindows"]
  let one (k : WindowKind) : List Window :=
    match J.frac? j (base ++ [k.key, "utilization"]),
          J.nat? j (base ++ [k.key, "resetsAt"]) with
    | some u, some r =>
      [{ kind := k, used := u, resetsAt := r, observedAt := observedAt, prov := .measured }]
    | _, _ => []
  one .fiveHour ++ one .sevenDay

/-- Token usage out of a `result` record's `usage` block. -/
def usageOfResult (j : Json) : TokenTally :=
  { input := J.nat j ["usage", "input_tokens"]
    output := J.nat j ["usage", "output_tokens"]
    cacheCreation := J.nat j ["usage", "cache_creation_input_tokens"]
    cacheRead := J.nat j ["usage", "cache_read_input_tokens"] }

/-- Accumulated state from one audit log. -/
structure AuditScan where
  tally : TokenTally := TokenTally.empty
  windows : List Window := []
  /-- Observation time of the `rate_limit_event` the windows came from. -/
  windowsAt : Epoch := 0
  deriving Repr, Inhabited

/-- Fold one audit record. Keeps the newest `rate_limit_event` seen, since an older
reading of the same window is strictly worse information. -/
def foldAudit (from_ to_ : Epoch) (s : AuditScan) (line : String) : AuditScan :=
  match J.parseLine line with
  | none => s
  | some j =>
    let ts := (J.iso? j ["timestamp"]).getD 0
    match J.str? j ["type"] with
    | some "rate_limit_event" =>
      if ts ≥ s.windowsAt then
        { s with windows := windowsOfRateLimitEvent j ts, windowsAt := ts }
      else s
    | some "result" =>
      if ts < from_ || ts > to_ then s
      else { s with tally := s.tally + usageOfResult j }
    | _ => s

/-- Scan one session's `audit.jsonl`. -/
def scanAudit (dir : System.FilePath) (from_ to_ : Epoch) : IO AuditScan := do
  let p := dir / "audit.jsonl"
  if !(← p.pathExists) then return {}
  let lines ← Ndjson.readAll p
  return lines.foldl (foldAudit from_ to_) {}

/-- Every `local_<uuid>.json` under the Cowork root.

The layout nests account then organisation, but the root also holds unrelated
directories (`skills-plugin`), so the walk is by shape rather than by name: descend two
levels and take what matches. -/
def metaFiles : IO (Array System.FilePath) := do
  let root ← Paths.coworkRoot
  let mut out : Array System.FilePath := #[]
  for acct in ← Paths.entries root do
    for org in ← Paths.entries acct do
      for f in ← Paths.entries org do
        if Paths.hasExt f "json" then
          if let some n := f.fileName then
            if (n.splitOn "local_").length > 1 then
              out := out.push f
  return out

/-- Load every Cowork session, with usage and any window readings.

Archived sessions are skipped entirely: they cannot spend. -/
def load (now from_ to_ : Epoch) : IO (Array CoworkSession) := do
  let mut out : Array CoworkSession := #[]
  -- The store is laid out `<accountUuid>/<orgUuid>/`, so the account is read straight
  -- off the path. The email is only shown when the default login is that same account.
  let login ← Account.readLogin ((← Paths.home) / ".claude.json")
  for f in ← metaFiles do
    let txt ← try IO.FS.readFile f catch _ => pure ""
    match parseMeta txt now with
    | none => pure ()
    | some (sess, cliId, archived) =>
      if archived then pure () else
      -- `local_<uuid>.json` sits beside the `local_<uuid>/` directory.
      let dir := f.withExtension ""
      let scan ← scanAudit dir from_ to_
      let orgDir := f.parent.getD ""
      let acctDir := orgDir.parent.getD ""
      let account : Option Account :=
        match acctDir.fileName, orgDir.fileName with
        | some a, some o =>
          let label := match login with
            | some l => if l.account == a && l.email != "" then l.email
                        else s!"account ·{String.ofList (a.toList.take 8)}"
            | none => s!"account ·{String.ofList (a.toList.take 8)}"
          some { key := Account.loginKey a o, label := label }
        | _, _ => none
      out := out.push
        { session := { sess with tally := scan.tally, account := account }
          cliSessionId := cliId
          windows := scan.windows }
  return out

/-! ## Checks -/

private def rateLimitRow : String :=
  "{\"type\":\"rate_limit_event\",\"timestamp\":\"2026-09-10T08:07:56.784Z\"," ++
  "\"rate_limit_info\":{\"status\":\"allowed_warning\",\"unifiedWindows\":{" ++
  "\"five_hour\":{\"utilization\":0,\"resetsAt\":1789045200}," ++
  "\"seven_day\":{\"utilization\":0.58,\"resetsAt\":1789178400}}}}"

private def resultRow : String :=
  "{\"type\":\"result\",\"timestamp\":\"2026-09-10T08:07:56Z\",\"usage\":{" ++
  "\"input_tokens\":18,\"cache_creation_input_tokens\":23096," ++
  "\"cache_read_input_tokens\":63443,\"output_tokens\":625}}"

private def scanned : AuditScan := [rateLimitRow, resultRow].foldl (foldAudit 0 2000000000) {}

-- Both unified windows are recovered from a real record.
#guard (scanned.windows.map (·.kind)) == [WindowKind.fiveHour, WindowKind.sevenDay]

-- `utilization: 0.58` is 58 %, not 0.58 %. Reading it on the statusline's scale would
-- understate the weekly window by a factor of a hundred.
#guard (scanned.windows.map (·.used)) == [0, 58000]
#guard (scanned.windows.map (·.resetsAt)) == [1789045200, 1789178400]

-- These readings are measurements, and are labelled as such.
#guard scanned.windows.all (fun w => w.prov == Provenance.measured)

-- A `result` row's usage is accumulated.
#guard scanned.tally.output == 625
#guard scanned.tally.cacheRead == 63443
#guard scanned.tally.total == 18 + 23096 + 63443 + 625

-- Out-of-window results do not count, but a rate-limit reading still does: it describes
-- the window's state now, not activity inside the window.
#guard ([resultRow].foldl (foldAudit 1900000000 2000000000) {}).tally.total == 0
#guard ([rateLimitRow].foldl (foldAudit 1900000000 2000000000) {}).windows.length == 2

-- A session active moments ago is a claimant; one idle for an hour is not.
#guard
  ((parseMeta "{\"sessionId\":\"local_x\",\"model\":\"claude-haiku-4-5\",\"lastActivityAt\":1789102000000,\"isArchived\":false}"
      1789102100).map (fun (r, _, _) => r.alive)) == some true
#guard
  ((parseMeta "{\"sessionId\":\"local_x\",\"model\":\"claude-haiku-4-5\",\"lastActivityAt\":1789102000000,\"isArchived\":false}"
      1789105700).map (fun (r, _, _) => r.alive)) == some false

-- An archived session never counts, however recent.
#guard
  ((parseMeta "{\"sessionId\":\"local_x\",\"lastActivityAt\":1789102000000,\"isArchived\":true}"
      1789102100).map (fun (r, _, _) => r.alive)) == some false

-- The CLI session linkage is preserved, so Cowork usage can be reconciled against it.
#guard
  ((parseMeta "{\"sessionId\":\"local_x\",\"cliSessionId\":\"b1eaf0c0\",\"lastActivityAt\":0}"
      0).map (fun (_, c, _) => c)) == some "b1eaf0c0"

end Stratify.Cowork
