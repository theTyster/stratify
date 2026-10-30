import Stratify.Types
import Stratify.Allocate

/-!
# Who splits a window with whom

Accounts (`Account.lean`) say which *credential* a session runs on. A credential is not
a window. One subscription can be reached through several credentials — a `/login` in
one shell, a `setup-token` in another — and all of them draw on the same window. And a
config directory's login can name a different account from the one an older session is
still running on. So two different account keys prove nothing about two different
windows.

Treating them as different anyway is wrong in the expensive direction: each side plans
as if the other did not exist, and the window is spent at a multiple of its paced rate.
That failure is silent, which is the worst kind.

## The rule: share, unless proven apart

Two sessions split a window unless there is positive evidence that they draw on
different windows. Exactly two things count as evidence:

* **Measured.** Fresh readings from the two credentials disagree about when the same
  kind of window resets. One window has one reset time, so two reset times are two
  windows.
* **Declared.** The operator marked a credential independent (`stratify account
  --independent`). Like `claim --user`, that declaration is the operator's to make,
  not an agent's: it is a claim about billing that nothing on the machine can check.

Anything else — a session with no known account, a reading with none, a credential that
has never produced a reading — shares with everyone. Over-counting claimants only
slows sessions down; under-counting overspends.

## What is proved

`window_not_oversubscribed`: if the sessions actually drawing on one window are
pairwise not proven apart, the grants they compute against that window sum to no more
than its budget, however the rest of the machine is partitioned. Its hypothesis is the
evidence being sound, and `readings_that_agree_do_not_separate` is the part of that
which is a fact about the arithmetic rather than about the world.
-/

namespace Stratify.Pool

/-- A fresh reading, reduced to what identifies its window. -/
structure Mark where
  key : String
  kind : WindowKind
  resetsAt : Epoch
  deriving Repr, DecidableEq, Inhabited

/-- Everything that can separate two credentials. -/
structure Evidence where
  /-- Readings recent enough to describe the current window. See `Collect`. -/
  marks : List Mark := []
  /-- Account keys the operator declared independent. -/
  independent : List String := []
  /-- Reset times closer than this are treated as the same window, so jitter can never
  split one window in two. -/
  gap : Nat := 300
  deriving Inhabited

def absDiff (a b : Nat) : Nat := (a - b) + (b - a)

/-- Fresh readings put `a` and `b` on different windows of some kind. -/
def provenApart (ev : Evidence) (a b : String) : Bool :=
  ev.marks.any fun m => m.key == a &&
    ev.marks.any fun n => n.key == b && n.kind == m.kind && decide (ev.gap < absDiff m.resetsAt n.resetsAt)

/-- `a` and `b` are known to draw on different windows. `""` is "no account known", which
is never distinct from anything. -/
def distinct (ev : Evidence) (a b : String) : Bool :=
  a != "" && b != "" && a != b &&
    (ev.independent.contains a || ev.independent.contains b || provenApart ev a b)

/-- Whether `a` and `b` might draw on the same window, and so must split it. -/
def mayShare (ev : Evidence) (a b : String) : Bool := !distinct ev a b

/-- A claimant as the split sees it. -/
structure Claimant where
  key : String
  weight : Milli
  deriving Repr, Inhabited

/-- Everyone a session with account `k` splits with. -/
def claimantsOf (ev : Evidence) (k : String) (cs : List Claimant) : List Claimant :=
  cs.filter fun c => mayShare ev k c.key

/-! ## Properties -/

theorem mayShare_self (ev : Evidence) (a : String) : mayShare ev a a = true := by
  simp [mayShare, distinct]

/-- A session with no known account shares with everyone, in both directions. -/
theorem mayShare_unattributed_left (ev : Evidence) (b : String) : mayShare ev "" b = true := by
  simp [mayShare, distinct]

theorem mayShare_unattributed_right (ev : Evidence) (a : String) : mayShare ev a "" = true := by
  simp [mayShare, distinct]

/-- Readings never separate credentials whose readings agree. Two sessions on one window
see one reset time, so measurement alone can never split a real window. -/
theorem readings_that_agree_do_not_separate (ev : Evidence) (a b : String)
    (h : ∀ m ∈ ev.marks, ∀ n ∈ ev.marks, m.key = a → n.key = b → n.kind = m.kind →
      absDiff m.resetsAt n.resetsAt ≤ ev.gap) :
    provenApart ev a b = false := by
  unfold provenApart
  rw [List.any_eq_false]
  intro m hm
  simp only [Bool.and_eq_true, beq_iff_eq, List.any_eq_true, decide_eq_true_eq, not_and,
    not_exists]
  intro hka n hn ⟨hkb, hkind⟩
  exact Nat.not_lt.mpr (h m hm n hn hka hkb hkind)

/-! ### The guarantee -/

theorem sumN_le_of_le {α : Type} (l : List α) (f g : α → Nat) (h : ∀ x ∈ l, f x ≤ g x) :
    sumN (l.map f) ≤ sumN (l.map g) := by
  induction l with
  | nil => simp
  | cons x xs ih =>
    simp only [List.map_cons, sumN_cons]
    exact Nat.add_le_add (h x (by simp)) (ih fun y hy => h y (by simp [hy]))

theorem le_sumN_of_mem {w : Nat} {ws : List Nat} (h : w ∈ ws) : w ≤ sumN ws := by
  induction ws with
  | nil => simp at h
  | cons x xs ih =>
    simp only [sumN_cons]
    rcases List.mem_cons.mp h with rfl | h'
    · exact Nat.le_add_right _ _
    · exact Nat.le_trans (ih h') (Nat.le_add_left _ _)

theorem sumN_sublist {l₁ l₂ : List Nat} (h : l₁.Sublist l₂) : sumN l₁ ≤ sumN l₂ := by
  induction h with
  | slnil => simp
  | cons a _ ih => simp only [sumN_cons]; exact Nat.le_trans ih (Nat.le_add_left _ _)
  | cons_cons a _ ih => simp only [sumN_cons]; exact Nat.add_le_add_left ih a

/-- Splitting over more weight never grants more. -/
theorem grant_anti_total (budget w S T : Nat) (hw : w ≤ S) (hST : S ≤ T) :
    grant budget w T ≤ grant budget w S := by
  unfold grant
  rcases Nat.eq_zero_or_pos S with hS | hS
  · subst hS
    have : w = 0 := Nat.le_zero.mp hw
    subst this
    simp
  · exact Nat.div_le_div_left hST hS

/-- Property 1, generalised: when each member of a group splits over at least the
group's own weight, the group's grants fit the budget. Each member may be splitting with
any number of outsiders as well; that only shrinks its grant. -/
theorem grants_le_budget_of_covering {α : Type} (budget : Mpp) (U : List α) (w T : α → Nat)
    (h : ∀ s ∈ U, sumN (U.map w) ≤ T s) :
    sumN (U.map fun s => grant budget (w s) (T s)) ≤ budget := by
  have step : sumN (U.map fun s => grant budget (w s) (T s))
      ≤ sumN (U.map fun s => grant budget (w s) (sumN (U.map w))) :=
    sumN_le_of_le U _ _ fun s hs =>
      grant_anti_total budget (w s) _ _ (le_sumN_of_mem (List.mem_map.mpr ⟨s, hs, rfl⟩)) (h s hs)
  refine Nat.le_trans step ?_
  have := grants_le_budget budget (U.map w)
  simpa [totalWeight, List.map_map, Function.comp_def] using this

/-- **9. No window is oversubscribed, however accounts are partitioned.**

`U` is the sessions that actually draw on one window, in any order consistent with the
claimant list. If no two of them are proven apart — which holds whenever the evidence is
sound — then the grants each computes from its own claimant set sum to no more than the
window's budget. -/
theorem window_not_oversubscribed (ev : Evidence) (budget : Mpp) (cs U : List Claimant)
    (hsub : U.Sublist cs)
    (hshare : ∀ s ∈ U, ∀ t ∈ U, mayShare ev s.key t.key = true) :
    sumN (U.map fun s =>
      grant budget s.weight (totalWeight ((claimantsOf ev s.key cs).map (·.weight)))) ≤ budget := by
  apply grants_le_budget_of_covering budget U (·.weight)
    (fun s => totalWeight ((claimantsOf ev s.key cs).map (·.weight)))
  intro s hs
  have hU : U.Sublist (claimantsOf ev s.key cs) := by
    have := hsub.filter (fun c => mayShare ev s.key c.key)
    rwa [List.filter_eq_self.mpr (fun t ht => hshare s hs t ht)] at this
  exact sumN_sublist (hU.map _)

/-! ## Checks -/

private def evOf (marks : List Mark) (ind : List String := []) : Evidence :=
  { marks := marks, independent := ind }

-- Different keys, no readings: they share.
#guard mayShare (evOf []) "cred:a" "cred:b"
-- Same reset time: still one window as far as anyone can tell.
#guard mayShare (evOf [⟨"cred:a", .sevenDay, 1000⟩, ⟨"cred:b", .sevenDay, 1000⟩]) "cred:a" "cred:b"
-- Jitter inside the gap does not split a window.
#guard mayShare (evOf [⟨"cred:a", .fiveHour, 1000⟩, ⟨"cred:b", .fiveHour, 1200⟩]) "cred:a" "cred:b"
-- Different reset times for the same kind: two windows.
#guard !mayShare (evOf [⟨"cred:a", .fiveHour, 1000⟩, ⟨"cred:b", .fiveHour, 9000⟩]) "cred:a" "cred:b"
-- Different kinds prove nothing.
#guard mayShare (evOf [⟨"cred:a", .fiveHour, 1000⟩, ⟨"cred:b", .sevenDay, 9000⟩]) "cred:a" "cred:b"
-- A declaration separates, from either side.
#guard !mayShare (evOf [] ["cred:b"]) "cred:a" "cred:b"
#guard !mayShare (evOf [] ["cred:b"]) "cred:b" "cred:a"
-- Nothing separates a session with no known account.
#guard mayShare (evOf [] ["cred:b"]) "" "cred:b"

end Stratify.Pool
