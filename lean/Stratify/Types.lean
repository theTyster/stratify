/-!
# stratify core types

Every quantity that the allocator reasons about is **fixed-point `Nat`**, not `Float`.

That is a deliberate choice. `Float` in Lean is an opaque primitive: `0.1 + 0.2 ≤ 0.3` is
not decidable by `decide`, associativity of `+` does not hold, and none of the six
properties in the plan could be proved about a `Float` allocator — they could only be
asserted. Percentages arrive from JSON as decimals, get converted once at the boundary
(`Json.lean`), and from then on live as `Mpp`, where every theorem is a first-order `Nat`
statement that `omega` and the core `Nat.div` lemmas can discharge.
-/

namespace Stratify

/-! ## Fixed-point scalars -/

/-- Milli-percentage-points. `1 mpp = 0.001 %`, so a full rate-limit window is
`100_000` mpp. Chosen so that a realistic statusline reading (`23.5` %) is exact. -/
abbrev Mpp := Nat

/-- A full window, in `Mpp`. -/
def fullWindow : Mpp := 100000

/-- Weight in milli-units: `1000` denotes weight `1.0`. -/
abbrev Milli := Nat

/-- Epoch seconds. -/
abbrev Epoch := Nat

/-- Token count. -/
abbrev Tokens := Nat

/-! ## Provenance

`stratify` reports measured and estimated numbers side by side, and must never let an
estimate be mistaken for a reading. Every derived figure carries its provenance. -/

/-- Where a number came from. `estimated` values are inferred from transcript activity
when the statusline sensor has not been installed or has not yet reported. -/
inductive Provenance where
  /-- Read from a statusline payload (or a Cowork `rate_limit_event`). -/
  | measured
  /-- Inferred from transcript activity; the denominator and window anchor are guesses. -/
  | estimated
  /-- No data at all.  -/
  | unknown
  deriving Repr, DecidableEq, Inhabited

/-- `true` only for a genuine measurement. -/
def Provenance.isMeasured : Provenance → Bool
  | .measured => true
  | _ => false

/-- How much a provenance is worth, for combining several of them. Higher is better
evidence. -/
def Provenance.rank : Provenance → Nat
  | .measured => 2
  | .estimated => 1
  | .unknown => 0

/-- Combine two provenances pessimistically: a summary over a measured reading and an
estimated one is an estimate. Claiming the better of the two would let one fresh window
launder the staleness of another. -/
def Provenance.worst (a b : Provenance) : Provenance :=
  if a.rank ≤ b.rank then a else b

/-! ## Rate-limit windows -/

/-- Which rate-limit window. Claude Code exposes all three on the statusline payload;
`spendLimit` only appears behind a Claude apps gateway. -/
inductive WindowKind where
  | fiveHour
  | sevenDay
  | spendLimit
  deriving Repr, DecidableEq, Inhabited

def WindowKind.key : WindowKind → String
  | .fiveHour => "five_hour"
  | .sevenDay => "seven_day"
  | .spendLimit => "spend_limit"

/-- Nominal duration of a window, in seconds. Used only for estimation when no
`resets_at` has ever been observed — the real boundary is never computed, it is read. -/
def WindowKind.nominalSeconds : WindowKind → Nat
  | .fiveHour => 5 * 3600
  | .sevenDay => 7 * 24 * 3600
  | .spendLimit => 30 * 24 * 3600

/-- One observed rate-limit window. `resetsAt` is always observed, never derived:
measured reset times on this account are sometimes hour-aligned and sometimes not
(13:00 vs 09:50 UTC), because the window anchors to first use. -/
structure Window where
  kind : WindowKind
  /-- Consumed fraction of the window. -/
  used : Mpp
  /-- Epoch second at which the window resets. -/
  resetsAt : Epoch
  /-- When this reading was taken. -/
  observedAt : Epoch
  prov : Provenance
  deriving Repr, DecidableEq, Inhabited

/-- Headroom left in a window, in `Mpp`, against a ceiling. Saturating: a window read
above the ceiling yields `0` rather than underflowing. -/
def Window.headroom (w : Window) (ceiling : Mpp) : Mpp :=
  ceiling - w.used

/-- Seconds until the window resets, relative to `now`. `0` once the window has rolled
over — callers treat that as "budget is fresh", never as a negative interval. -/
def Window.secondsLeft (w : Window) (now : Epoch) : Nat :=
  w.resetsAt - now

/-- Has this window already rolled over as of `now`? -/
def Window.rolledOver (w : Window) (now : Epoch) : Bool :=
  w.resetsAt ≤ now

/-! ### How long a reading outlives its window

Claude Code drops a window from the statusline payload the moment its `resets_at`
passes, and each window is dropped independently. A reading can therefore outlive the
window it measured, and the sensor goes quiet for that window precisely when the
interesting thing happens.

That makes rollover two different situations wearing one name:

* the window reset *moments* ago, so its replacement is genuinely near-empty, and
  carrying on against a full ceiling is true;
* the window reset *hours* ago, so an unobserved amount has been spent into a
  replacement window we have never seen. The reading now describes a window two
  generations gone.

Reading the second case as the first is what let a session be handed a full weekly
grant while the binding window sat at 97 %. `WindowState` is the distinction. -/

/-- How a reading relates to the window it describes, at `now`. -/
inductive WindowState where
  /-- `now` is still inside the window this reading describes. -/
  | live
  /-- The window reset inside the grace period; its replacement is new enough that
  treating it as empty is still true. -/
  | rolledOver
  /-- The window reset long enough ago that the replacement's usage is unobserved. -/
  | expired
  deriving Repr, DecidableEq, Inhabited

/-- Classify a reading against `now`. `grace` is how long after a reset a reading may
still stand in for the replacement window. -/
def Window.state (w : Window) (grace : Nat) (now : Epoch) : WindowState :=
  if now < w.resetsAt then .live
  else if now - w.resetsAt ≤ grace then .rolledOver
  else .expired

/-- What a reading is worth as evidence, at `now`.

Three separate downgrades, and they are not interchangeable:

* an **expired** reading is not evidence about the current window at all;
* a **rolled-over** reading is an inference — we measured that the window reset, not
  what has been spent since — so it is `estimated`, never `measured`;
* a **live** reading of a long window can still go stale: usage only grows, so an old
  reading understates it, and understating usage is the direction that overspends. -/
def Window.provAt (w : Window) (staleAfter grace : Nat) (now : Epoch) : Provenance :=
  match w.state grace now with
  | .expired => .unknown
  | .rolledOver => .estimated
  | .live => if now - w.observedAt > staleAfter then .estimated else .measured

/-- A reading that may be scheduled against. Expired readings are excluded: the correct
response to one is to say the window is unknown, not to plan against a number that
described a window which has since been replaced. -/
def Window.usable (w : Window) (grace : Nat) (now : Epoch) : Bool :=
  w.state grace now != WindowState.expired

/-! ## Sessions -/

/-- Session liveness state as recorded in `~/.claude/sessions/<pid>.json`. -/
inductive SessionStatus where
  | busy
  | waiting
  | idle
  | unknown
  deriving Repr, DecidableEq, Inhabited

def SessionStatus.ofString : String → SessionStatus
  | "busy" => .busy
  | "waiting" => .waiting
  | "idle" => .idle
  | _ => .unknown

def SessionStatus.toString : SessionStatus → String
  | .busy => "busy"
  | .waiting => "waiting"
  | .idle => "idle"
  | .unknown => "unknown"

/-- A session that is actively spending against the window. `busy` is the only status
that consumes right now, but `waiting` and `idle` sessions are still *claimants* on the
window: they will resume, and an idle session that is excluded from the split gets
starved the moment it wakes. -/
def SessionStatus.isSpending : SessionStatus → Bool
  | .busy => true
  | _ => false

/-- Which product surface a session belongs to. Cowork sessions live in a different
store (`local-agent-mode-sessions/`) with their own audit log, and are not mirrored
into `~/.claude/projects/`. -/
inductive Origin where
  | cli
  | cowork
  deriving Repr, DecidableEq, Inhabited

def Origin.toString : Origin → String
  | .cli => "cli"
  | .cowork => "cowork"

/-- Token counts for one model within a window. Kept split because they are billed and
rate-limited differently — a cache read is not a fresh input token. -/
structure TokenTally where
  input : Tokens := 0
  output : Tokens := 0
  cacheCreation : Tokens := 0
  cacheRead : Tokens := 0
  deriving Repr, DecidableEq, Inhabited

def TokenTally.add (a b : TokenTally) : TokenTally :=
  { input := a.input + b.input
    output := a.output + b.output
    cacheCreation := a.cacheCreation + b.cacheCreation
    cacheRead := a.cacheRead + b.cacheRead }

instance : Add TokenTally := ⟨TokenTally.add⟩

def TokenTally.empty : TokenTally := {}

/-- Every token the tally accounts for. -/
def TokenTally.total (t : TokenTally) : Tokens :=
  t.input + t.output + t.cacheCreation + t.cacheRead

/-- One live session and what is known about it. -/
structure SessionRec where
  origin : Origin
  /-- OS pid. `0` for a Cowork session, which has no pid of its own in the store. -/
  pid : Nat
  sessionId : String
  cwd : String
  /-- Display name: `--name`/`/rename`, else the derived or AI title. -/
  name : String
  status : SessionStatus
  /-- `procStart` as recorded in the session JSON. Retained verbatim for the
  liveness cross-check; see `Sessions.lean` for the UTC-vs-local trap. -/
  procStart : String
  version : String
  /-- Model id from the most recent assistant row, e.g. `claude-opus-5`. Empty when
  the session has not yet made a request. -/
  model : String
  /-- Reasoning effort from the most recent assistant row. -/
  effort : String
  /-- Whether the pid is live *and* its start time matches `procStart`. -/
  alive : Bool
  /-- Tokens attributed to this session inside the window under consideration. -/
  tally : TokenTally
  /-- Last activity seen for this session, epoch seconds. -/
  lastActivity : Epoch
  deriving Repr, Inhabited

/-! ## Priority

Modelled on Unix `nice`: lower number means more favourable scheduling. A session
running "nicely" yields window share to its peers, which is exactly the posture the
plan asks for. -/

/-- Niceness in `[-20, 19]`, matching `nice(2)`. Stored as `Int` and clamped on
construction, so no out-of-range value can reach the weight table. -/
structure Nice where
  val : Int
  deriving Repr, DecidableEq, Inhabited

namespace Nice

/-- Most favourable niceness, as in `nice(2)`. -/
def lo : Int := -20
/-- Least favourable niceness, as in `nice(2)`. -/
def hi : Int := 19

/-- Clamp an arbitrary integer into the valid nice range. Total by construction, so no
out-of-range niceness can reach the weight table. -/
def ofInt (i : Int) : Nice :=
  ⟨max Nice.lo (min Nice.hi i)⟩

/-- Default niceness: `0`, weight `1.0`. -/
def default : Nice := ⟨0⟩

end Nice

/-- Who set a session's priority. An explicit human declaration outranks anything an
agent inferred about itself — agents are not trusted to promote themselves. -/
inductive PrioritySource where
  /-- Declared by the user. Authoritative. -/
  | user
  /-- Inferred by an agent for its own session. Advisory. -/
  | inferred
  /-- Nothing declared; the default applies. -/
  | default
  deriving Repr, DecidableEq, Inhabited

def PrioritySource.ofString : String → PrioritySource
  | "user" => .user
  | "inferred" => .inferred
  | _ => .default

def PrioritySource.toString : PrioritySource → String
  | .user => "user"
  | .inferred => "inferred"
  | .default => "default"

/-- Rank for conflict resolution: a `user` declaration beats an `inferred` one beats
the default, regardless of which arrived later. -/
def PrioritySource.rank : PrioritySource → Nat
  | .user => 2
  | .inferred => 1
  | .default => 0

/-- A session's resolved priority. -/
structure Priority where
  nice : Nice
  source : PrioritySource
  /-- When the declaration was made. -/
  declaredAt : Epoch
  deriving Repr, DecidableEq, Inhabited

def Priority.default : Priority :=
  { nice := Nice.default, source := .default, declaredAt := 0 }

/-! ## Allocation output -/

/-- One session's share of the binding window. -/
structure Alloc where
  sessionId : String
  weight : Milli
  /-- Headroom granted to this session, in `Mpp`. -/
  grant : Mpp
  deriving Repr, DecidableEq, Inhabited

/-- The scheduling decision handed to an agent. The agent does no arithmetic: it reads
`sleepSeconds` or `cron` and obeys. -/
structure Plan where
  sessionId : String
  /-- Which window constrains this session right now. -/
  binding : WindowKind
  weight : Milli
  /-- This session's share of the binding window's headroom. -/
  grant : Mpp
  /-- How much of the window one sprint may consume. -/
  sprintBudget : Mpp
  /-- Delay before the next sprint, for `ScheduleWakeup`. -/
  sleepSeconds : Nat
  /-- The same cadence as a 5-field cron expression, for `CronCreate`. -/
  cron : String
  /-- Seconds until the binding window resets. -/
  secondsLeft : Nat
  /-- `true` when the binding window is exhausted and the only correct action is to
  wait for the reset. -/
  waitForReset : Bool
  /-- Provenance of the binding window reading. -/
  prov : Provenance
  /-- How many live sessions the headroom was split across. -/
  claimants : Nat
  deriving Repr, Inhabited

/-! ## Guard rails

The allocator has no hidden constants. Everything it is permitted to assume lives here,
so a reviewer can see the whole policy surface at once. -/

structure Guards where
  /-- Plan against this ceiling rather than 100 %, leaving a reserve for the
  unschedulable: a human typing into a session, a `/compact`, an interactive burst. -/
  ceiling : Mpp := 90000
  /-- Never sleep less than this. Keeps a hot session from spinning. -/
  minSleep : Nat := 60
  /-- Never sleep longer than this in one hop. `ScheduleWakeup` clamps to 3600 anyway,
  and a longer hop makes the loop unresponsive to changes in the session population. -/
  maxSleep : Nat := 3600
  /-- Smallest slice of the window worth waking up to spend, in `Mpp` (0.5 %).

  This is what makes the schedule calibration-free. Rather than converting tokens to
  window percentage — which needs an empirical constant that could be wrong, and would
  mis-pace everything if it were — the grant is simply divided into slices of at least
  this size, and the runway is divided into that many sprints. Both quantities are
  observed directly. -/
  minSprintMpp : Mpp := 500
  /-- Re-sample the session population at least this often, in sprints. -/
  resampleEvery : Nat := 4
  /-- How old a reading of a *live* window may be and still count as a measurement.

  Five hours, the shortest window there is: beyond that, any reading has outlived at
  least one whole five-hour cycle. -/
  staleAfter : Nat := 5 * 3600
  /-- How long after a window's `resets_at` a reading may still stand in for the
  replacement window.

  Five minutes. The sensor fires on every statusline render, and Claude Code forces a
  render when a window reaches its `resets_at`, so a fresh reading should arrive within
  seconds. Past this, silence means the replacement window is being spent into
  unobserved — which is a different fact, and the one that matters. -/
  rolloverGrace : Nat := 300
  /-- How recently the sensor must have written for it to count as live.

  Eight times the installed `refreshInterval` of 15 s, so an ordinary gap between
  renders never reads as a dead sensor. -/
  sensorLiveWithin : Nat := 120
  deriving Repr, DecidableEq, Inhabited

def Guards.default : Guards := {}

/-! ## Sensor samples

One reading of the statusline payload. This is the only continuously-available source
of true window state: `used_percentage` and `resets_at` appear nowhere on disk, so
without these samples the denominator and the reset time can only be guessed. -/

/-- A window reading inside a sample. -/
structure WindowSample where
  used : Mpp
  resetsAt : Epoch
  deriving Repr, DecidableEq, Inhabited

/-- One statusline render, reduced to the fields that matter for scheduling.

Kept small on purpose: the encoded line must stay under `PIPE_BUF` (512 bytes) so a
single `O_APPEND` write is atomic and concurrent sessions cannot interleave. -/
structure Sample where
  /-- When the sample was taken, by our own clock. -/
  ts : Epoch
  sessionId : String
  model : String
  effort : String
  fiveHour : Option WindowSample
  sevenDay : Option WindowSample
  spendLimit : Option WindowSample
  /-- Tokens currently in the context window, from the most recent API response. -/
  ctxInput : Tokens
  ctxOutput : Tokens
  /-- Session cost so far, in thousandths of a US cent, to stay integral. -/
  costMicroUsd : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Build the `Window` list a sample carries, tagged as measured. -/
def Sample.windows (s : Sample) : List Window :=
  let mk (k : WindowKind) (o : Option WindowSample) : List Window :=
    match o with
    | none => []
    | some ws =>
      [{ kind := k, used := ws.used, resetsAt := ws.resetsAt
         observedAt := s.ts, prov := .measured }]
  mk .fiveHour s.fiveHour ++ mk .sevenDay s.sevenDay ++ mk .spendLimit s.spendLimit

end Stratify
