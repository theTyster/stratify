import Stratify.Types

/-!
# The stratification allocator

This is the whole policy surface. Given the observed windows, the live session
population and each session's declared niceness, it answers one question: *how long
should this session wait before its next sprint?*

Everything here is exact `Nat` arithmetic, which is what lets the six properties at the
bottom of the file be **proved** rather than asserted. The division is floor division
throughout, and that is load-bearing: the unallocated remainder is precisely what keeps
the split from oversubscribing the window.
-/

namespace Stratify

/-! ## Summation

A local `sumN` rather than `List.sum`: it is structurally recursive on the spine, so the
inductive proofs below go through by `simp [sumN]` without unfolding a fold. -/

/-- Sum of a list of naturals. -/
def sumN : List Nat → Nat
  | [] => 0
  | x :: xs => x + sumN xs

@[simp] theorem sumN_nil : sumN [] = 0 := rfl

@[simp] theorem sumN_cons (x : Nat) (xs : List Nat) : sumN (x :: xs) = x + sumN xs := rfl

/-- Floor division distributes *sub*-additively over a sum: the discarded remainders can
only lose. Holds for `c = 0` too, where both sides are `0`. -/
theorem add_div_le_div_add (a b c : Nat) : a / c + b / c ≤ (a + b) / c := by
  match c with
  | 0 => simp
  | c + 1 =>
    rw [Nat.le_div_iff_mul_le (Nat.succ_pos c), Nat.add_mul]
    exact Nat.add_le_add (Nat.div_mul_le_self a (c + 1)) (Nat.div_mul_le_self b (c + 1))

/-- Summing after dividing never exceeds dividing after summing. -/
theorem sumN_div_le (l : List Nat) (c : Nat) : sumN (l.map (· / c)) ≤ sumN l / c := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    simp only [List.map_cons, sumN_cons]
    exact Nat.le_trans (Nat.add_le_add_left ih _) (add_div_le_div_add x (sumN xs) c)

/-- Scalar multiplication commutes with summation. -/
theorem sumN_map_mul (k : Nat) (l : List Nat) :
    sumN (l.map (fun x => k * x)) = k * sumN l := by
  induction l with
  | nil => simp
  | cons x xs ih => simp only [List.map_cons, sumN_cons, ih, Nat.mul_add]

/-! ## Niceness to weight

`weight = 1000 · 2^(−nice/10)`, tabulated. The shape is Unix `nice`, but deliberately
gentler than Linux CFS: CFS spans roughly 5900× across the nice range, which would
starve a deprioritised session outright. A 14.9× spread means a `nice 19` session still
makes steady progress while yielding most of the window to its peers — which is the
point of running "nicely" rather than not running at all.

Index into the table is `nice + 20`, so the table is dense over the whole legal range
and `Nice.ofInt` has already clamped anything out of bounds. -/

/-- `1000 · 2^(−nice/10)` for `nice ∈ [-20, 19]`, indexed by `nice + 20`. -/
def niceWeightTable : Array Milli :=
  #[4000, 3732, 3482, 3249, 3031, 2828, 2639, 2462, 2297, 2144,
    2000, 1866, 1741, 1625, 1516, 1414, 1320, 1231, 1149, 1072,
    1000,  933,  871,  812,  758,  707,  660,  616,  574,  536,
     500,  467,  435,  406,  379,  354,  330,  308,  287,  268]

/-- Scheduling weight for a niceness. Total: out-of-range input cannot occur after
`Nice.ofInt`, and would fall back to the neutral weight if it did. -/
def niceWeight (n : Nice) : Milli :=
  niceWeightTable.getD (n.val + 20).toNat 1000

/-- Weight of a resolved priority. -/
def weightOf (p : Priority) : Milli := niceWeight p.nice

/-! ## Budget and runway -/

/-- Headroom in a window, with rollover handled: once `now` has passed the observed
`resetsAt`, the window is fresh and the whole ceiling is available again. This is where
"after the 5 hours pass, keep working" comes from — no special case in the caller. -/
def budgetOf (g : Guards) (w : Window) (now : Epoch) : Mpp :=
  if w.rolledOver now then g.ceiling else w.headroom g.ceiling

/-- Seconds of runway before the window resets. After a rollover the observed
`resetsAt` is stale, so fall back to the window's nominal length rather than reporting
zero seconds and dividing by it. -/
def runwayOf (w : Window) (now : Epoch) : Nat :=
  if w.rolledOver now then w.kind.nominalSeconds else w.secondsLeft now

/-- The window permitting the lower burn rate is the binding constraint. Rates are
compared by cross-multiplication to stay in exact `Nat` arithmetic:
`bA/rA ≤ bB/rB ↔ bA·rB ≤ bB·rA`. -/
def moreBinding (g : Guards) (now : Epoch) (a b : Window) : Window :=
  if budgetOf g a now * runwayOf b now ≤ budgetOf g b now * runwayOf a now then a else b

/-- The binding window across every window observed.

Total on `List Window`, so it needs an answer for the empty list. The answer it gives —
a window at zero usage — is only ever reached through `planFor`, which handles the
empty case before calling here. It is *not* a model of "no reading": an unobserved
window read as `used := 0` is a claim that the window is empty, which is exactly the
claim that must not be made. See `unknownPlan`. -/
def bindingWindow (g : Guards) (now : Epoch) (ws : List Window) : Window :=
  match ws with
  | [] =>
    { kind := .fiveHour, used := 0, resetsAt := now, observedAt := now, prov := .unknown }
  | w :: rest => rest.foldl (moreBinding g now) w

/-! ## The split -/

/-- Total weight across claimants. -/
def totalWeight (ws : List Milli) : Milli := sumN ws

/-- One session's share of the headroom.

Floor division, deliberately: the remainder is left unallocated, and that slack is
exactly what `grants_le_budget` relies on. A `total` of zero yields zero, since `Nat`
division by zero is zero — no special case needed. -/
def grant (budget : Mpp) (w : Milli) (total : Milli) : Mpp :=
  budget * w / total

/-- Clamp a proposed interval into the guard-rail range. -/
def clampSleep (g : Guards) (s : Nat) : Nat :=
  max g.minSleep (min g.maxSleep s)

/-- How many sprints the grant divides into.

At least one, so the runway is never divided by zero and a session with any budget at
all is always told to do something. -/
def sprintsFor (g : Guards) (grantMpp : Mpp) : Nat :=
  max 1 (grantMpp / g.minSprintMpp)

/-- Window slice for a single sprint. -/
def sprintBudgetFor (g : Guards) (grantMpp : Mpp) : Mpp :=
  grantMpp / sprintsFor g grantMpp

/-- The interval between sprints.

A session owns `grant` mpp over `runway` seconds. Cutting the grant into
`sprintsFor` slices and the runway into the same number of intervals spends the grant
evenly across the whole window instead of in a burst at the start.

Note what is *not* here: any conversion between tokens and window percentage. Both
inputs are observed — the grant from a statusline reading, the runway from an observed
`resets_at` — so there is no empirical constant to get wrong. -/
def sleepFor (g : Guards) (grantMpp : Mpp) (runway : Nat) : Nat :=
  if grantMpp = 0 then g.maxSleep
  else clampSleep g (runway / sprintsFor g grantMpp)

/-- Cadence as a 5-field cron expression.

The minute offset is derived from the session id rather than fixed at `0`. Claude Code's
own scheduling guidance warns that everyone who asks for "hourly" lands on `0 *`, so a
deterministic per-session offset spreads concurrent sessions across the hour without
introducing randomness — the same session always gets the same offset. -/
def cronFor (sessionId : String) (sleepSeconds : Nat) : String :=
  let offset := (sessionId.hash % 60).toNat
  let minutes := max 1 ((sleepSeconds + 59) / 60)
  if minutes ≤ 59 then
    s!"*/{minutes} * * * *"
  else
    let hours := max 1 ((minutes + 59) / 60)
    if hours ≤ 23 then s!"{offset} */{hours} * * *"
    else s!"{offset} 0 * * *"

/-! ## Putting it together -/

/-- The interval between sprints while blind.

A per-plan grant bounds one sprint, not a sequence of them. At the shortest legal sleep
a session would take a 0.5 % sprint every 60 s — 30 % of the window an hour, twenty-two
times an equal share, and with no reading arriving to correct it. Bounding the grant
while leaving the cadence unbounded is not a fail-safe; it is the same fail-open shape
in slower motion.

So the cadence is derived rather than fixed: spend one minimum sprint per slice of the
*shortest* window an equal split would allow. That is the rate this session would be
granted if the five-hour window were at the ceiling and shared evenly, which is the most
generous assumption available that is not a guess about the reading itself.

Equal shares, not weighted ones: niceness apportions a known quantity, and there is
nothing known here to apportion. A favourably-niced session should not be able to spend
faster precisely when nobody can see the window. -/
def unknownSleep (g : Guards) (claimants : Nat) : Nat :=
  clampSleep g
    (WindowKind.fiveHour.nominalSeconds * g.minSprintMpp * (max 1 claimants) / g.ceiling)

/-- The plan issued when no window can be scheduled against.

Both tempting answers are wrong.

Treating an unobserved window as empty is what let a session be handed a full weekly
grant while the binding window sat at 97 % — the failure this branch exists to prevent.
But refusing to plan at all is not obviously better: Claude Code can decline to report a
window for hours, and a tool that stalls every stratified run for that whole time has
turned a missing reading into an outage.

So: the smallest slice worth waking up for, at a cadence slow enough that repeating it
indefinitely stays inside an equal share (`unknownSleep`). A session keeps making
bounded progress, and the moment a real reading appears it gets a real grant. `prov`
says `unknown`, and the skill is required to pass that through rather than present it as
a measurement. -/
def unknownPlan (g : Guards) (sessionId : String) (claimants : Nat)
    (myWeight : Milli) : Plan :=
  { sessionId := sessionId
    -- Nominally the five-hour window: the shortest, hence the most conservative thing
    -- to be uncertain about. `prov := .unknown` is what carries the real meaning.
    binding := .fiveHour
    weight := myWeight
    grant := g.minSprintMpp
    sprintBudget := g.minSprintMpp
    sleepSeconds := unknownSleep g claimants
    cron := cronFor sessionId (unknownSleep g claimants)
    -- Not zero because the window is exhausted, but because its runway is unknown.
    secondsLeft := 0
    -- Not a reset to wait for: there is no known window to wait on. Waiting here would
    -- be waiting forever.
    waitForReset := false
    prov := .unknown
    claimants := claimants }

/-- Compute one session's plan.

`weights` is every live claimant's weight including this session's own; `myWeight` must
be one of them. Nothing here is calibrated: every input is an observed quantity, so a
plan is a pure function of the snapshot.

`windows` must already be filtered to readings that are still evidence about the
current window — `Collect.snapshot` drops expired ones. An empty list therefore means
"nothing is known", not "nothing constrains". -/
def planFor
    (g : Guards) (now : Epoch) (sessionId : String)
    (windows : List Window) (weights : List Milli) (myWeight : Milli) : Plan :=
  match windows with
  | [] => unknownPlan g sessionId weights.length myWeight
  | _ =>
  let w := bindingWindow g now windows
  let budget := budgetOf g w now
  let runway := runwayOf w now
  let total := totalWeight weights
  let myGrant := grant budget myWeight total
  let sleep := sleepFor g myGrant runway
  { sessionId := sessionId
    binding := w.kind
    weight := myWeight
    grant := myGrant
    sprintBudget := sprintBudgetFor g myGrant
    sleepSeconds := sleep
    cron := cronFor sessionId sleep
    secondsLeft := runway
    waitForReset := myGrant == 0
    prov := w.prov
    claimants := weights.length }

/-! ## Properties

The six claims the design rests on. Each is about the functions above as written, not
about an idealised model of them.

Stated, not overstated: these are properties of this allocator's arithmetic. They say
nothing about whether the *inputs* are accurate — that is what `Provenance` is for. -/

section Properties

variable (g : Guards) (budget : Mpp) (w total : Milli)

/-- **1. No oversubscription.** Summed across every claimant, the grants never exceed
the budget being split. The floor division's discarded remainder is what pays for this. -/
theorem grants_le_budget (budget : Mpp) (ws : List Milli) :
    sumN (ws.map (fun w => grant budget w (totalWeight ws))) ≤ budget := by
  have hmap : (ws.map (fun w => grant budget w (totalWeight ws)))
      = (ws.map (fun w => budget * w)).map (· / totalWeight ws) := by
    simp [grant, List.map_map, Function.comp_def]
  rw [hmap]
  refine Nat.le_trans (sumN_div_le _ _) ?_
  rw [sumN_map_mul]
  exact Nat.div_le_of_le_mul (Nat.le_of_eq (Nat.mul_comm budget (sumN ws)))

/-- **2. Monotonicity.** A heavier weight never receives a smaller grant. Priority is
therefore never counterproductive: declaring yourself more important cannot cost you
window share. -/
theorem grant_mono (budget : Mpp) {w₁ w₂ total : Milli} (h : w₁ ≤ w₂) :
    grant budget w₁ total ≤ grant budget w₂ total :=
  Nat.div_le_div_right (Nat.mul_le_mul_left budget h)

/-- **3. Non-starvation.** Whenever a session's fair share amounts to at least one
whole `Mpp`, it receives a strictly positive grant.

The bound is stated honestly. When `budget · w < total` the floor genuinely is zero —
the session's fair share is under one milli-percentage-point — and the correct
behaviour is the long sleep that `sleepFor` returns, not a fabricated grant. -/
theorem grant_pos {budget : Mpp} {w total : Milli}
    (htotal : 0 < total) (hshare : total ≤ budget * w) :
    0 < grant budget w total :=
  Nat.div_pos hshare htotal

/-- **4. Bounded sleep.** The interval is always inside the guard rails, so no plan can
ever ask an agent to spin or to disappear. -/
theorem clampSleep_bounds (g : Guards) (s : Nat) (h : g.minSleep ≤ g.maxSleep) :
    g.minSleep ≤ clampSleep g s ∧ clampSleep g s ≤ g.maxSleep := by
  refine ⟨Nat.le_max_left _ _, ?_⟩
  exact Nat.max_le.mpr ⟨h, Nat.min_le_left _ _⟩

/-- The same bound, for the interval actually emitted. -/
theorem sleepFor_bounds (g : Guards) (gm runway : Nat) (h : g.minSleep ≤ g.maxSleep) :
    g.minSleep ≤ sleepFor g gm runway ∧ sleepFor g gm runway ≤ g.maxSleep := by
  unfold sleepFor
  split
  · exact ⟨h, Nat.le_refl _⟩
  · exact clampSleep_bounds g _ h

/-- **4b. The sprint schedule does not overspend the grant.**

Running every sprint the plan allows for consumes no more than the grant it was derived
from. Without this, property 1 would only bound a single instant: the split could be
sound while the sequence of sprints it licenses still blew through the window. -/
theorem sprint_schedule_within_grant (g : Guards) (grantMpp : Mpp) :
    sprintsFor g grantMpp * sprintBudgetFor g grantMpp ≤ grantMpp := by
  unfold sprintBudgetFor
  exact Nat.mul_div_le grantMpp (sprintsFor g grantMpp)

/-- A sprint never claims more than the whole grant, however small the grant is. -/
theorem sprintBudget_le_grant (g : Guards) (grantMpp : Mpp) :
    sprintBudgetFor g grantMpp ≤ grantMpp := by
  unfold sprintBudgetFor
  exact Nat.div_le_self _ _

/-- There is always at least one sprint, so the runway is never divided by zero. -/
theorem sprintsFor_pos (g : Guards) (grantMpp : Mpp) : 0 < sprintsFor g grantMpp := by
  unfold sprintsFor
  exact Nat.lt_of_lt_of_le Nat.zero_lt_one (Nat.le_max_left _ _)

/-- **6. Rollover safety.** Once the window has reset, the budget is the full ceiling
and the runway is strictly positive — never a negative or zero interval to divide by.
This is what lets a stratified session keep working past a window boundary. -/
theorem budgetOf_rolledOver (g : Guards) (w : Window) (now : Epoch)
    (h : w.rolledOver now = true) : budgetOf g w now = g.ceiling := by
  simp [budgetOf, h]

theorem runwayOf_pos (w : Window) (now : Epoch) (h : w.rolledOver now = true) :
    0 < runwayOf w now := by
  simp only [runwayOf, h, if_true]
  cases w.kind <;> decide

/-! ### 7. Not knowing is bounded, and is not the same as knowing zero

The defect these three properties close: an unobserved window used to reach the
allocator as `used := 0`, which is a claim that it is empty. Under a nearly-exhausted
window that is the most expensive possible wrong answer, because it is wrong in the
direction of spending. -/

/-- **7a.** With nothing to schedule against, the grant is exactly one minimum sprint —
never the ceiling, and never zero. Holds for every weight and every claimant count, so
no priority declaration can talk its way out of the bound. -/
theorem unknown_is_bounded (g : Guards) (now : Epoch) (sid : String)
    (weights : List Milli) (myWeight : Milli) :
    (planFor g now sid [] weights myWeight).grant = g.minSprintMpp := rfl

/-- **7b.** And it does not stall: an unknown window is not a reset to wait for, so a
run keeps making bounded progress instead of hanging until Claude Code volunteers a
reading. -/
theorem unknown_does_not_stall (g : Guards) (now : Epoch) (sid : String)
    (weights : List Milli) (myWeight : Milli) :
    (planFor g now sid [] weights myWeight).waitForReset = false := rfl

/-- **7c.** The uncertainty is reported, not absorbed. -/
theorem unknown_is_labelled (g : Guards) (now : Epoch) (sid : String)
    (weights : List Milli) (myWeight : Milli) :
    (planFor g now sid [] weights myWeight).prov = Provenance.unknown := rfl

/-- **7d.** The blind cadence stays inside the guard rails, so bounding the sequence of
sprints did not come at the cost of a plan that spins or disappears. -/
theorem unknownSleep_bounds (g : Guards) (c : Nat) (h : g.minSleep ≤ g.maxSleep) :
    g.minSleep ≤ unknownSleep g c ∧ unknownSleep g c ≤ g.maxSleep :=
  clampSleep_bounds g _ h

/-- **7e.** The blind cadence does not speed up as more sessions arrive.

Each additional claimant makes every session wait longer, exactly as a smaller share
would. Without this, going blind with thirteen sessions running would license thirteen
times the spend of going blind alone. -/
theorem unknownSleep_mono (g : Guards) {a b : Nat} (h : a ≤ b) :
    unknownSleep g a ≤ unknownSleep g b := by
  unfold unknownSleep clampSleep
  have hmax : max 1 a ≤ max 1 b :=
    Nat.max_le.mpr ⟨Nat.le_max_left 1 b, Nat.le_trans h (Nat.le_max_right 1 b)⟩
  have hdiv : WindowKind.fiveHour.nominalSeconds * g.minSprintMpp * (max 1 a) / g.ceiling
      ≤ WindowKind.fiveHour.nominalSeconds * g.minSprintMpp * (max 1 b) / g.ceiling :=
    Nat.div_le_div_right (Nat.mul_le_mul_left _ hmax)
  have hmin : min g.maxSleep
      (WindowKind.fiveHour.nominalSeconds * g.minSprintMpp * (max 1 a) / g.ceiling)
      ≤ min g.maxSleep
      (WindowKind.fiveHour.nominalSeconds * g.minSprintMpp * (max 1 b) / g.ceiling) :=
    Nat.le_min.mpr ⟨Nat.min_le_left _ _, Nat.le_trans (Nat.min_le_right _ _) hdiv⟩
  exact Nat.max_le.mpr ⟨Nat.le_max_left _ _, Nat.le_trans hmin (Nat.le_max_right _ _)⟩

/-! ### 8. An expired reading is not evidence

A reading whose `resets_at` passed more than `grace` ago describes a window that has
since been replaced by one we have never seen. -/

/-- **8a.** Past the grace period, a reading is expired.

Written with explicit `Nat` lemmas rather than `omega`. `Epoch` is an `abbrev` for
`Nat`, and `omega` declines to collect facts stated at the alias — it reports "no usable
constraints found" even with the hypothesis in scope. -/
theorem state_expired_of_long_past (w : Window) (grace : Nat) (now : Epoch)
    (h : w.resetsAt + grace < now) : w.state grace now = WindowState.expired := by
  unfold Window.state
  have h1 : ¬ (now < w.resetsAt) :=
    Nat.not_lt.mpr (Nat.le_of_lt (Nat.lt_of_le_of_lt (Nat.le_add_right _ grace) h))
  have h2 : ¬ (now - w.resetsAt ≤ grace) :=
    Nat.not_le.mpr (Nat.lt_sub_of_add_lt (Nat.add_comm w.resetsAt grace ▸ h))
  simp [h1, h2]

/-- **8b.** An expired reading is never reported as a measurement, at any staleness
threshold. This is the claim `status` used to get wrong: it called a two-hour-old
reading of an already-reset window `measured`, because it compared the reading's age
against a fixed five hours instead of against the window's own reset time. -/
theorem expired_not_measured (w : Window) (staleAfter grace : Nat) (now : Epoch)
    (h : w.state grace now = WindowState.expired) :
    w.provAt staleAfter grace now = Provenance.unknown := by
  simp [Window.provAt, h]

/-- **8c.** And it is excluded from the readings the allocator may use, rather than
being passed through at a lower confidence. There is no honest number to report for a
window whose replacement was never observed. -/
theorem expired_not_usable (w : Window) (grace : Nat) (now : Epoch)
    (h : w.state grace now = WindowState.expired) : w.usable grace now = false := by
  simp [Window.usable, h]

end Properties

/-! ### Executable checks

Facts about the tables and guard rails, checked at elaboration time. -/

/-- The default guard rails are internally consistent. -/
example : Guards.default.minSleep ≤ Guards.default.maxSleep := by decide

/-- The ceiling leaves a genuine reserve rather than planning to exhaustion. -/
example : Guards.default.ceiling < fullWindow := by decide

/-- The weight table covers the whole legal nice range, densely. -/
example : niceWeightTable.size = (Nice.hi - Nice.lo + 1).toNat := by decide

/-- Neutral niceness has neutral weight. -/
example : niceWeight Nice.default = 1000 := by decide

/-- The extremes land where the formula says. -/
example : niceWeight (Nice.ofInt (-20)) = 4000 := by decide
example : niceWeight (Nice.ofInt 19) = 268 := by decide

/-- Clamping is total: out-of-range niceness collapses onto the endpoints rather than
falling off the table. -/
example : niceWeight (Nice.ofInt (-999)) = niceWeight (Nice.ofInt (-20)) := by decide
example : niceWeight (Nice.ofInt 999) = niceWeight (Nice.ofInt 19) := by decide

/-- Weight is antitone in niceness at every adjacent step, so being nicer never buys
more window. Adjacent descent over 39 pairs; pairwise antitonicity follows. -/
example :
    (List.range 39).all (fun i =>
      niceWeightTable.getD (i + 1) 0 ≤ niceWeightTable.getD i 0) = true := by
  decide

end Stratify
