import Lean.Data.Json
import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Paths

/-!
# The live session registry

`~/.claude/sessions/<pid>.json` is written by each running Claude Code session. It is
the authoritative list of who exists, but it is *not* authoritative about who is still
running: the file outlives the process. A stale entry has to be detected, not trusted.

## Two traps

**Pid reuse.** A pid alone proves nothing. On this machine `~/.claude/sessions/65031.json`
describes a session from 26 August, and pid 65031 *is* currently alive — as an unrelated
process. Counting it as a claimant would silently shrink every real session's share.

The guard is to cross-check the recorded `procStart` against the live process's actual
start time, and to require the process to be `claude`. Both must agree.

**The timezone mismatch.** `procStart` is written in UTC; `ps -o lstart=` prints local
time. The same process start reads `Fri Sep 11 04:42:51 2026` in one and
`Thu Sep 10 23:42:51 2026` in the other. Comparing them as strings, or as instants,
marks every live session dead. `Time.sameInstantModuloTZ` accepts the pair when their
difference looks like a UTC offset — see `Time.lean` for why that is sound.

Residual risk, stated plainly: a recycled pid belonging to *another* `claude` process
whose start time differs from the recorded one by an exact whole number of
quarter-hours under 14 would still pass. That is a narrow enough window to accept, and
the failure is graceful — one extra claimant, so every session gets a slightly smaller
share. The bias is toward under-spending.

## Failing safe

If `ps` cannot be run at all, every registry entry is treated as alive. That
over-counts claimants, which divides the window more finely and slows everyone down.
The opposite default — assuming sessions are dead — would hand out a share of the
window that is already spoken for. When in doubt, under-allocate.
-/

namespace Stratify.Sessions

open Lean

/-- What the OS says about one pid. -/
structure ProcInfo where
  pid : Nat
  /-- `lstart`, in local time, read as UTC. Only meaningful via
  `Time.sameInstantModuloTZ`. -/
  startAsUtc : Epoch
  /-- Executable name, used to reject a recycled pid that is not Claude Code. -/
  comm : String
  deriving Repr, Inhabited

private def splitWs (s : String) : List String :=
  (s.toList.foldr (init := ([], [])) (fun c (cur, acc) =>
      if c == ' ' || c == '\t' then ([], if cur.isEmpty then acc else String.ofList cur :: acc)
      else (c :: cur, acc))
    |> fun (cur, acc) => if cur.isEmpty then acc else String.ofList cur :: acc)

/-- Parse one `ps -o pid=,lstart=,comm=` line.

`lstart` is always exactly five whitespace-separated tokens
(`Thu Sep 10 23:42:51 2026`), even when the day is space-padded to two characters, so
the split is unambiguous and anything after token six is the command. -/
def parsePsLine (line : String) : Option ProcInfo := do
  match splitWs line with
  | pidS :: dow :: mon :: day :: tm :: yr :: rest => do
    let pid ← pidS.toNat?
    let start ← Time.parseCtimeAsUtc s!"{dow} {mon} {day} {tm} {yr}"
    pure { pid := pid, startAsUtc := start, comm := " ".intercalate rest }
  | _ => none

/-- Ask the OS about a set of pids in one call.

One `ps` invocation for the whole registry rather than one per session: with a dozen
live sessions the difference is a dozen process spawns on a path that runs every
sprint. -/
def probePids (pids : Array Nat) : IO (Std.HashMap Nat ProcInfo) := do
  if pids.isEmpty then return {}
  let list := ",".intercalate (pids.toList.map toString)
  let out ← try
      IO.Process.output { cmd := "ps", args := #["-o", "pid=,lstart=,comm=", "-p", list] }
    catch _ => pure { exitCode := 1, stdout := "", stderr := "" }
  let mut m : Std.HashMap Nat ProcInfo := {}
  for line in out.stdout.splitOn "\n" do
    if let some info := parsePsLine line then
      m := m.insert info.pid info
  return m

/-- Is the process behind this registry entry the one that wrote it?

Requires the command to look like Claude Code *and* the recorded start time to match
the live one modulo a timezone offset.

The command test is a substring match, not a basename comparison, because
`ps -o comm=` **truncates**. A session launched from a versioned install shows up as
`/Users/ty/.local/share/claude/v` — the basename is a truncated path component, not
`claude`, and three live sessions on this machine were being dropped as dead by a
stricter test. Loosening it is safe: the start-time check is the real discriminator,
and this one only has to reject an unrelated program that inherited the pid. -/
def isLive (recordedProcStart : String) (info : Option ProcInfo) : Bool :=
  match info with
  | none => false
  | some i =>
    let looksLikeClaude := (i.comm.splitOn "claude").length > 1
    match Time.parseCtimeAsUtc recordedProcStart with
    | none => looksLikeClaude
    | some recorded => looksLikeClaude && Time.sameInstantModuloTZ recorded i.startAsUtc

/-- Decode one `~/.claude/sessions/<pid>.json`. -/
def parseSessionJson (txt : String) : Option SessionRec := do
  let j ← J.parseLine txt
  let sid ← J.str? j ["sessionId"]
  pure {
    origin := .cli
    pid := J.nat j ["pid"]
    sessionId := sid
    cwd := J.str j ["cwd"]
    name := J.str j ["name"]
    status := SessionStatus.ofString (J.str j ["status"])
    procStart := J.str j ["procStart"]
    version := J.str j ["version"]
    model := ""
    effort := ""
    alive := false
    tally := TokenTally.empty
    -- `updatedAt`/`statusUpdatedAt` are milliseconds since the epoch.
    lastActivity := (J.nat j ["updatedAt"]) / 1000 }

/-- Every CLI session in the registry, with liveness resolved.

Entries that fail to parse are dropped rather than guessed at. -/
def loadCli : IO (Array SessionRec) := do
  let dir ← Paths.sessionsDir
  let files := (← Paths.entries dir).filter (Paths.hasExt · "json")
  let mut recs : Array SessionRec := #[]
  for f in files do
    let txt ← try IO.FS.readFile f catch _ => pure ""
    if let some r := parseSessionJson txt then
      recs := recs.push r
  let probed ← probePids (recs.map (·.pid))
  -- `ps` failing wholesale must not mark a live fleet dead; see the note above.
  let psWorked := !probed.isEmpty || recs.isEmpty
  return recs.map fun r =>
    { r with alive := if psWorked then isLive r.procStart (probed.get? r.pid) else true }

/-! ## Transcript location

The per-project directory name is the session's `cwd` with `/` and `.` replaced by `-`,
so `/Users/ty/.dotfiles` becomes `-Users-ty--dotfiles`. That rule is Claude Code's, not
ours, so the derived path is treated as a hint: if it misses, fall back to scanning the
project directories for the session id. -/

/-- Claude Code's project-directory name for a working directory. -/
def slugOfCwd (cwd : String) : String :=
  String.ofList (cwd.toList.map fun c => if c == '/' || c == '.' then '-' else c)

/-- Locate a session's transcript. -/
def transcriptPath (sessionId cwd : String) : IO (Option System.FilePath) := do
  let root ← Paths.projectsDir
  let guess := root / slugOfCwd cwd / s!"{sessionId}.jsonl"
  if ← guess.pathExists then return some guess
  for d in ← Paths.entries root do
    let p := d / s!"{sessionId}.jsonl"
    if ← p.pathExists then return some p
  return none

/-! ## Checks -/

-- A real `ps` line, including the space-padded day that a naive split mishandles.
#guard
  (parsePsLine "  59134 Thu Sep 10 23:42:51 2026 /Users/ty/.local/bin/claude").map (·.pid)
    == some 59134
#guard
  (parsePsLine "  16823 Wed Sep  9 10:18:13 2026 claude").map (·.pid) == some 16823
#guard
  (parsePsLine "  16823 Wed Sep  9 10:18:13 2026 claude").map (·.comm) == some "claude"

-- The registry/`ps` pair from this machine: five hours apart, same process.
#guard
  isLive "Fri Sep 11 04:42:51 2026"
    (parsePsLine "  59134 Thu Sep 10 23:42:51 2026 /Users/ty/.local/bin/claude")

-- A truncated `ps -o comm=` path still counts. This exact shape was dropping three
-- live sessions on this machine.
#guard
  isLive "Thu Sep 10 20:37:37 2026"
    (parsePsLine "  91224 Thu Sep 10 15:37:37 2026 /Users/ty/.local/share/claude/v")

-- A long-lived session is still live: pid 65031 started on 26 August and is running.
-- The recorded and observed times differ by exactly the local offset.
#guard
  isLive "Wed Aug 26 22:39:22 2026"
    (parsePsLine "  65031 Wed Aug 26 17:39:22 2026 claude")

-- Pid reuse: the pid is alive but its start time is unrelated to the recorded one.
#guard
  !(isLive "Wed Aug 26 22:39:22 2026"
      (parsePsLine "  65031 Fri Sep 11 02:00:00 2026 claude"))

-- A recycled pid running something else is rejected even when the clock lines up.
#guard
  !(isLive "Fri Sep 11 04:42:51 2026"
      (parsePsLine "  59134 Thu Sep 10 23:42:51 2026 /usr/bin/node"))

-- A pid the OS does not know is not alive.
#guard !(isLive "Fri Sep 11 04:42:51 2026" none)

-- Project-directory slugs, including the doubled dash a dotfile directory produces.
#guard slugOfCwd "/Users/ty/Projects/mine/stratify" == "-Users-ty-Projects-mine-stratify"
#guard slugOfCwd "/Users/ty/.dotfiles" == "-Users-ty--dotfiles"
#guard slugOfCwd "/private/tmp" == "-private-tmp"

-- A real registry record.
#guard
  (parseSessionJson
    "{\"pid\":59134,\"sessionId\":\"c9db1741\",\"cwd\":\"/Users/ty/Projects/mine/stratify\",\"name\":\"stratify-d7\",\"status\":\"busy\",\"procStart\":\"Fri Sep 11 04:42:51 2026\",\"version\":\"2.1.268\",\"updatedAt\":1789102605342}").map
    (fun r => (r.pid, r.status, r.name, r.lastActivity))
    == some (59134, SessionStatus.busy, "stratify-d7", 1789102605)

-- An entry without a session id is unusable and is dropped, not defaulted.
#guard (parseSessionJson "{\"pid\":1}").isNone
#guard (parseSessionJson "garbage").isNone

end Stratify.Sessions
