import Stratify

/-!
# Proof hygiene and non-vacuity

Two things a passing `lake build` does not establish on its own, checked here so that
`run-checks.sh` can assert them.

## 1. Axiom hygiene

`#print axioms` reports the real footing of each proof term, so a `sorry` — which shows
up as `sorryAx` — cannot hide behind a green build.

What the properties actually rest on is Lean's three standard axioms: `propext`,
`Quot.sound` and `Classical.choice`. The arithmetic ones need only the first two; the
two ledger-determinism theorems reach `Classical.choice` through `omega`, which uses it
whenever it has to prove a goal-side disjunction — as `Key.ble_total` does. That is an
`omega` implementation detail, not a design choice here, and it is the same footing
essentially all of Mathlib stands on.

So the assertion `run-checks.sh` makes is the one that carries information: **no
`sorryAx`, and no axiom outside that standard three**. A custom axiom appearing in this
list would mean something was postulated rather than proved.

## 2. Non-vacuity

A conditional property whose hypotheses are unsatisfiable is true and worthless. An
unconditional bound that is trivially slack is barely better. So for each property below
there is a witness at realistic values: numbers taken from an actual reading on this
account (41.2 % of the five-hour window consumed, a 90 % planning ceiling, four
claimants at neutral niceness).

None of this is a verification judgement. It is the evidence that the properties say
something about inputs the tool will really see.
-/

namespace Stratify.Evals

open Stratify

/-! ## The reference scenario

A 41.2 % consumed five-hour window under a 90 % ceiling leaves 48 800 mpp of headroom,
split four ways at neutral weight. -/

def g : Guards := Guards.default
def budget : Mpp := 48800
def weights : List Milli := [1000, 1000, 1000, 1000]
def total : Milli := totalWeight weights

-- The scenario is the one it claims to be: headroom is ceiling minus a real reading.
example : Guards.default.ceiling - 41200 = budget := by decide
example : total = 4000 := by decide

/-! ## 1. No oversubscription — and the bound is tight

Vacuity would look like every grant being zero. Instead the four grants sum to 48 800
of an available 48 800: the bound is exactly attained here, and the theorem is doing
real work rather than bounding nothing. -/

def grants : List Mpp := weights.map (fun w => grant budget w total)

example : grants = [12200, 12200, 12200, 12200] := by decide
example : sumN grants = 48800 := by decide
example : 0 < sumN grants := by decide

-- The floor division's discarded remainder is what pays for the bound. With a weight
-- vector that does not divide evenly, the sum falls strictly short rather than over.
def odd : List Milli := [4000, 1000, 1000, 268]
example : sumN (odd.map (fun w => grant budget w (totalWeight odd))) < budget := by decide

/-! ## 2. Monotonicity, non-trivially

The inequality is strict at the ends of the nice range, so the theorem is not merely
restating reflexivity. -/

example : grant budget (niceWeight (Nice.ofInt 19)) total
            < grant budget (niceWeight (Nice.ofInt 0)) total := by decide
example : grant budget (niceWeight (Nice.ofInt 0)) total
            < grant budget (niceWeight (Nice.ofInt (-20))) total := by decide

/-! ## 3. Non-starvation — the hypotheses are reachable

`grant_pos` is conditional on `0 < total` and `total ≤ budget * w`. Both hold in the
reference scenario, and the grant it guarantees is a real 12.2 % rather than a
technicality. -/

example : 0 < total := by decide
example : total ≤ budget * 1000 := by decide
example : 0 < grant budget 1000 total := by decide

-- Reachable at the far end of the nice range too: a maximally yielding session among
-- thirteen claimants still receives a positive grant, which is the whole point of
-- running nicely rather than not running.
def crowded : List Milli := List.replicate 12 1000 ++ [niceWeight (Nice.ofInt 19)]
example : totalWeight crowded ≤ budget * niceWeight (Nice.ofInt 19) := by decide
example : 0 < grant budget (niceWeight (Nice.ofInt 19)) (totalWeight crowded) := by decide

-- And the honest boundary: below one whole mpp the floor genuinely is zero, which is
-- why the theorem carries the hypothesis instead of claiming positivity outright.
example : grant 1 1 4000 = 0 := by decide

/-! ## 4. Bounded sleep — the guard rails are consistent

The bound is conditional on `minSleep ≤ maxSleep`, which the shipped guards satisfy. -/

example : g.minSleep ≤ g.maxSleep := by decide
example : g.minSleep = 60 ∧ g.maxSleep = 3600 := by decide

-- Both ends of the clamp are actually reachable, so neither branch is dead code: a
-- four-hour runway split into 24 sprints wants 600 s, a short runway wants less than
-- the floor, and a long one more than the ceiling.
example : sleepFor g 12200 14400 = 600 := by decide
example : sleepFor g 12200 60 = g.minSleep := by decide
example : sleepFor g 12200 400000 = g.maxSleep := by decide
example : sleepFor g 0 14400 = g.maxSleep := by decide

/-! ## 4b. The sprint sequence stays inside the grant, non-trivially

Vacuity here would be `sprintsFor = 1` and `sprintBudget = 0`. Instead a 12.2 % grant
divides into 24 sprints of 0.508 % each, and 24 × 508 = 12 192 ≤ 12 200. -/

example : sprintsFor g 12200 = 24 := by decide
example : sprintBudgetFor g 12200 = 508 := by decide
example : 1 < sprintsFor g 12200 := by decide
example : 0 < sprintBudgetFor g 12200 := by decide
example : sprintsFor g 12200 * sprintBudgetFor g 12200 = 12192 := by decide

-- The smallest grant still yields one usable sprint rather than zero of them.
example : sprintsFor g 1 = 1 := by decide
example : sprintBudgetFor g 1 = 1 := by decide

/-! ## 6. Rollover safety — the precondition is reachable

`rolledOver` is satisfiable by construction, and past the reset the budget really is the
full ceiling and the runway really is the nominal window rather than zero. -/

def rolled : Window :=
  { kind := .fiveHour, used := 95000, resetsAt := 1789102000
    observedAt := 1789101900, prov := .measured }

def afterReset : Epoch := 1789102605

example : rolled.rolledOver afterReset = true := by decide
example : budgetOf g rolled afterReset = g.ceiling := by decide
example : 0 < runwayOf rolled afterReset := by decide
example : runwayOf rolled afterReset = 18000 := by decide

-- And the pre-rollover branch is reachable too, so the `if` is not decided one way for
-- every input the tool can see.
def live : Window :=
  { kind := .fiveHour, used := 41200, resetsAt := 1789117005
    observedAt := 1789102605, prov := .measured }

example : live.rolledOver afterReset = false := by decide
example : budgetOf g live afterReset = 48800 := by decide
example : runwayOf live afterReset = 14400 := by decide

/-! ## 7 and 8. Not knowing, at the numbers that produced the defect

The witness here is not invented. It is the incident: the readings actually in this
account's `samples.ndjson` at the moment `stratify status` reported a full weekly
allowance while the five-hour window sat at 97 % used.

Both readings had outlived the windows they measured. `u5 = 44.0 %` was written at
`t = 1789160999` against `r5 = 1789161000` — one second before that window reset — and
`u7 = 93.0 %` at `t = 1789178387` against `r7 = 1789178400`, thirteen seconds before
that one did. Each window then vanished from the statusline payload, because Claude
Code drops a window once its `resets_at` passes. -/

def incidentNow : Epoch := 1789186214

def lapsed5h : Window :=
  { kind := .fiveHour, used := 44000, resetsAt := 1789161000
    observedAt := 1789160999, prov := .measured }

def lapsed7d : Window :=
  { kind := .sevenDay, used := 93000, resetsAt := 1789178400
    observedAt := 1789178387, prov := .measured }

-- Both readings are of windows that reset hours ago: seven and two hours respectively.
example : incidentNow - lapsed5h.resetsAt = 25214 := by decide
example : incidentNow - lapsed7d.resetsAt = 7814 := by decide

-- So both are expired, and neither may be scheduled against.
example : lapsed5h.state g.rolloverGrace incidentNow = WindowState.expired := by decide
example : lapsed7d.state g.rolloverGrace incidentNow = WindowState.expired := by decide
example : lapsed5h.usable g.rolloverGrace incidentNow = false := by decide
example : lapsed7d.usable g.rolloverGrace incidentNow = false := by decide

-- And neither is a measurement. Under the old age-based rule the seven-day reading was
-- two hours old against a five-hour threshold, so it was reported `measured` — of a
-- window that had already reset.
example : lapsed7d.provAt g.staleAfter g.rolloverGrace incidentNow = Provenance.unknown := by
  decide
example : incidentNow - lapsed7d.observedAt ≤ g.staleAfter := by decide

-- The plan that follows: one minimum sprint, labelled unknown, and no stall. Before the
-- change this session was offered 6.9 % of the window over thirteen sprints.
-- `#guard` rather than `decide`: a `Plan` carries a `String` session id.
#guard (planFor g incidentNow "s" [] weights 1000).grant == g.minSprintMpp
#guard (planFor g incidentNow "s" [] weights 1000).prov == Provenance.unknown
#guard (planFor g incidentNow "s" [] weights 1000).waitForReset == false

/-! ### The blind cadence, at the claimant counts that actually occur

A bounded grant is not a bounded spend. Repeating a 0.5 % sprint at the shortest legal
sleep is 30 % of the window an hour — worse, over a long blind stretch, than the
fail-open behaviour it replaces. So the interval is derived from the claimant count, and
these are the numbers it produces. -/

-- Thirteen sessions, the population on this account when the defect was found: one
-- sprint every 21 minutes, which is an equal share of a five-hour window at the ceiling.
example : unknownSleep g 13 = 1300 := by decide
example : 3600 / 1300 * g.minSprintMpp < 90000 / 13 / 5 + 1 := by decide

-- Alone, it is faster; in a crowd, slower. Neither escapes the guard rails.
example : unknownSleep g 1 = 100 := by decide
example : unknownSleep g 4 = 400 := by decide
example : unknownSleep g 100 = g.maxSleep := by decide
example : g.minSleep ≤ unknownSleep g 1 ∧ unknownSleep g 1 ≤ g.maxSleep := by decide

-- Monotone, non-trivially: the interval genuinely moves with the population rather than
-- sitting on a clamp for every realistic input.
example : unknownSleep g 1 < unknownSleep g 13 := by decide
example : unknownSleep g 13 < unknownSleep g 36 := by decide

#guard (planFor g incidentNow "s" [] weights 1000).sleepSeconds == unknownSleep g 4

-- Non-vacuity in the other direction: the bound is a real restriction, not the value
-- the allocator would have produced anyway. The same session with a live reading gets
-- twenty-four times as much.
#guard (planFor g afterReset "s" [live] weights 1000).grant == 12200
example : g.minSprintMpp < 12200 := by decide

-- And the grace branch is reachable, so `expired` is not simply what every rolled-over
-- reading becomes. A window that reset thirty seconds ago still restores the ceiling —
-- the behaviour "after the five hours pass, keep working" depends on.
def justRolled : Window :=
  { rolled with resetsAt := afterReset - 30, observedAt := afterReset - 90 }

example : justRolled.state g.rolloverGrace afterReset = WindowState.rolledOver := by decide
example : justRolled.usable g.rolloverGrace afterReset = true := by decide
example : budgetOf g justRolled afterReset = g.ceiling := by decide
example : 0 < runwayOf justRolled afterReset := by decide

-- A rolled-over reading is an inference about the replacement window, never a
-- measurement of it, and says so.
example : justRolled.provAt g.staleAfter g.rolloverGrace afterReset = Provenance.estimated := by
  decide

-- All three states are inhabited, so no branch of the classification is dead.
example : live.state g.rolloverGrace afterReset = WindowState.live := by decide

-- Where the grace line falls. `rolled` above sits 605 s past its reset, so it is past
-- the five-minute grace and reads as expired — a deliberate boundary, not an oversight:
-- ten minutes of thirteen concurrent sessions spending into an unobserved window is
-- already a real quantity, and assuming it is zero is the direction that overspends.
-- `budgetOf_rolledOver` still holds of it, because that theorem is about `rolledOver`,
-- which asks only whether the reset time has passed.
example : afterReset - rolled.resetsAt = 605 := by decide
example : rolled.state g.rolloverGrace afterReset = WindowState.expired := by decide
example : budgetOf g rolled afterReset = g.ceiling := by decide

/-! ## 5. Ledger determinism — the reordering is observable

Swapping two records is only an interesting invariance if the records differ and if the
resolved value is one a reorder could plausibly disturb. Both declarations below carry
different niceness, different timestamps and different sources. -/

def userDecl : Ledger.Entry :=
  { ts := 1789100000, sessionId := "s", nice := -5, source := .user }
def agentDecl : Ledger.Entry :=
  { ts := 1789102000, sessionId := "s", nice := 10, source := .inferred }

-- `#guard` rather than `decide` throughout this section: an `Entry` carries a `String`
-- field, and `String` primitives are opaque to the kernel. `#guard` evaluates instead
-- of reducing, which is the right tool and still fails the build when it is false.
#guard userDecl != agentDecl
#guard userDecl.key != agentDecl.key

-- The later inferred record does not win, so the resolution is not simply "last write".
#guard Ledger.resolve [userDecl, agentDecl] == Ledger.resolve [agentDecl, userDecl]
#guard (Ledger.resolve [agentDecl, userDecl]).source == PrioritySource.user
#guard (Ledger.resolve [agentDecl, userDecl]).nice == Nice.ofInt (-5)

-- The weights those two declarations map to differ, so a wrong resolution would be
-- visible in the emitted plan rather than absorbed.
example : niceWeight (Nice.ofInt (-5)) ≠ niceWeight (Nice.ofInt 10) := by decide

/-! ## 9. Accounts — the separation is real, and the hypothesis is satisfiable

Two keys whose fresh readings disagree are split apart, so `claimantsOf` really does
exclude someone; and the window's actual users in that fixture do pairwise share, so
`window_not_oversubscribed` is not vacuously true of it. -/

private def ev9 : Pool.Evidence :=
  { marks := [⟨"a", .fiveHour, 1000⟩, ⟨"b", .fiveHour, 9000⟩] }
private def cs9 : List Pool.Claimant := [⟨"a", 1000⟩, ⟨"b", 1000⟩, ⟨"", 1000⟩, ⟨"a", 500⟩]
private def users9 : List Pool.Claimant := [⟨"a", 1000⟩, ⟨"", 1000⟩, ⟨"a", 500⟩]

#guard (Pool.claimantsOf ev9 "a" cs9).length == 3
#guard (Pool.claimantsOf ev9 "b" cs9).length == 2
#guard users9.all fun s => users9.all fun t => Pool.mayShare ev9 s.key t.key
-- And without the readings, nothing separates them.
#guard (Pool.claimantsOf {} "a" cs9).length == 4

/-! ## Axiom footing

One line per property. `run-checks.sh` asserts the count, the absence of `sorryAx`, and
that nothing outside Lean's standard three axioms appears. -/

-- 1. No oversubscription.
#print axioms Stratify.grants_le_budget
-- 2. Monotonicity.
#print axioms Stratify.grant_mono
-- 3. Non-starvation.
#print axioms Stratify.grant_pos
-- 4. Bounded sleep.
#print axioms Stratify.clampSleep_bounds
#print axioms Stratify.sleepFor_bounds
-- 4b. The sprint sequence stays inside the grant.
#print axioms Stratify.sprint_schedule_within_grant
#print axioms Stratify.sprintBudget_le_grant
#print axioms Stratify.sprintsFor_pos
-- 5. Ledger fold determinism.
#print axioms Stratify.Ledger.resolve_swap
#print axioms Stratify.Ledger.resolve_idem_head
-- 6. Rollover safety.
#print axioms Stratify.budgetOf_rolledOver
#print axioms Stratify.runwayOf_pos
-- 7. An unknown window is bounded, does not stall, is labelled, and its cadence is
-- bounded and does not speed up as claimants arrive.
#print axioms Stratify.unknown_is_bounded
#print axioms Stratify.unknown_does_not_stall
#print axioms Stratify.unknown_is_labelled
#print axioms Stratify.unknownSleep_bounds
#print axioms Stratify.unknownSleep_mono
-- 8. An expired reading is not evidence.
#print axioms Stratify.state_expired_of_long_past
#print axioms Stratify.expired_not_measured
#print axioms Stratify.expired_not_usable
-- 9. However accounts are split, no window is oversubscribed; agreeing readings never
-- split a window.
#print axioms Stratify.Pool.window_not_oversubscribed
#print axioms Stratify.Pool.grants_le_budget_of_covering
#print axioms Stratify.Pool.readings_that_agree_do_not_separate
#print axioms Stratify.Pool.mayShare_unattributed_left
#print axioms Stratify.Pool.mayShare_unattributed_right

end Stratify.Evals
