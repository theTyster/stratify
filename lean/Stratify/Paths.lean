import Stratify.Types

/-!
# Filesystem locations

Every path `stratify` touches, in one place, so the blast radius is legible.

`STRATIFY_HOME` overrides the runtime-state directory. The evals and the concurrency
test rely on it to run against a scratch directory instead of the real ledger — without
it, testing the sensor would mean writing into live scheduling state.

Nothing here writes outside `STRATIFY_HOME` (default `~/.claude/stratify`). The Claude
Code directories are opened read-only.
-/

namespace Stratify.Paths

/-- `$HOME`, or `.` if unset. -/
def home : IO System.FilePath := do
  return (← IO.getEnv "HOME").getD "." |> System.FilePath.mk

/-- Runtime-state directory. `STRATIFY_HOME` overrides it. -/
def stratifyHome : IO System.FilePath := do
  match ← IO.getEnv "STRATIFY_HOME" with
  | some p => return System.FilePath.mk p
  | none => return (← home) / ".claude" / "stratify"

/-- Sensor output: one line per statusline render. -/
def samplesFile : IO System.FilePath := do return (← stratifyHome) / "samples.ndjson"

/-- Declarations: priority claims, sprint boundaries, yields. -/
def ledgerFile : IO System.FilePath := do return (← stratifyHome) / "ledger.ndjson"

/-! ## Claude Code (read-only) -/

/-- Live session registry, one `<pid>.json` per session. -/
def sessionsDir : IO System.FilePath := do return (← home) / ".claude" / "sessions"

/-- Per-project transcript directories. -/
def projectsDir : IO System.FilePath := do return (← home) / ".claude" / "projects"

/-- Global settings. Read to answer "is the statusline shim installed?", which is a
different question from "is a reading fresh?" and must not be inferred from one. -/
def settingsFile : IO System.FilePath := do return (← home) / ".claude" / "settings.json"

/-- Cowork's session store. Laid out as
`<root>/<accountUuid>/<orgUuid>/local_<uuid>.json` alongside a `local_<uuid>/`
directory holding that session's `audit.jsonl`. -/
def coworkRoot : IO System.FilePath := do
  return (← home) / "Library" / "Application Support" / "Claude"
    / "local-agent-mode-sessions"

/-! ## Helpers -/

/-- Directory entries, or `#[]` when the directory is absent or unreadable.

Absence is normal, not exceptional: Cowork may never have run on a given machine, and
the runtime-state directory does not exist before the first sample. -/
def entries (dir : System.FilePath) : IO (Array System.FilePath) := do
  if !(← dir.pathExists) then return #[]
  try
    return (← dir.readDir).map (·.path)
  catch _ => return #[]

/-- Does this path name a file whose extension is `ext`? -/
def hasExt (p : System.FilePath) (ext : String) : Bool :=
  p.extension == some ext

end Stratify.Paths
