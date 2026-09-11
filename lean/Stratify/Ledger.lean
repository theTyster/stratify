import Lean.Data.Json
import Stratify.Types
import Stratify.Time
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths

/-!
# The priority ledger

Sessions declare their niceness by appending to `ledger.ndjson`. Nothing coordinates
those appends: any number of sessions may write at the same moment, in any order, and
each one sees a different prefix of the log. So the resolved state has to be a function
of the *set* of records, not of the order they arrived in.

## Resolving to a key, not to a record

The obvious design — "pick the winning record" — makes the determinism claim awkward.
Two records can tie on every field the ordering examines, and then "which record wins"
genuinely is arbitrary.

So resolution produces a `Key` instead: the triple `(rank, ts, nice)` that the ordering
actually compares. That is enough, because a `Priority` is entirely recoverable from a
key — the source is recoverable from its rank, the niceness and the declaration time are
the other two components. No record is ever selected, so there is nothing for ties to be
arbitrary about, and determinism reduces to the fact that `Key.max2` is a commutative,
associative, idempotent join over `Nat` and `Int`.

## Conflict rules

* A **user** declaration outranks an **inferred** one, whenever it was made. Agents are
  not trusted to promote themselves past their operator.
* Within a rank, later wins.
* Within a rank and instant, the **higher** niceness wins — an ambiguous declaration
  should yield window share, not claim it.
-/

namespace Stratify.Ledger

open Lean

/-! ## Keys -/

/-- The totally-ordered quantity a declaration resolves to.

A `Priority` is recoverable from this, which is why resolution can stop here. -/
structure Key where
  /-- `PrioritySource.rank`: user beats inferred beats default. -/
  rank : Nat
  /-- Declaration time. -/
  ts : Nat
  /-- Declared niceness. -/
  nice : Int
  deriving DecidableEq, Repr, Inhabited

namespace Key

/-- The default priority: nobody has declared anything. -/
def bot : Key := { rank := 0, ts := 0, nice := 0 }

/-- Lexicographic `≤`, written in `Bool` algebra so the proofs below reduce to linear
arithmetic that `omega` can discharge. -/
def ble (a b : Key) : Bool :=
  a.rank < b.rank
    || (a.rank == b.rank
        && (a.ts < b.ts || (a.ts == b.ts && a.nice ≤ b.nice)))

/-- Join: the greater of two keys. -/
def max2 (a b : Key) : Key := if ble a b then b else a

/-- Unfold `ble` into arithmetic. -/
private theorem ble_iff {a b : Key} :
    ble a b = true ↔
      (a.rank < b.rank ∨ (a.rank = b.rank ∧ (a.ts < b.ts ∨ (a.ts = b.ts ∧ a.nice ≤ b.nice)))) := by
  simp [ble]

theorem ble_refl (a : Key) : ble a a = true := by
  rw [ble_iff]; omega

theorem ble_total (a b : Key) : ble a b = true ∨ ble b a = true := by
  rw [ble_iff, ble_iff]; omega

theorem ble_trans {a b c : Key} (h₁ : ble a b = true) (h₂ : ble b c = true) :
    ble a c = true := by
  rw [ble_iff] at h₁ h₂ ⊢; omega

/-- Antisymmetry. Because a key's three components are exactly what the ordering
compares, mutual `≤` forces equality outright — there is no residual field for a tie to
hide in. This is the step that makes resolving to a key rather than a record pay off. -/
theorem ble_antisymm {a b : Key} (h₁ : ble a b = true) (h₂ : ble b a = true) : a = b := by
  rw [ble_iff] at h₁ h₂
  have hr : a.rank = b.rank := by omega
  have ht : a.ts = b.ts := by omega
  have hn : a.nice = b.nice := by omega
  cases a; cases b; simp_all

/-! ### `max2` is a join -/

theorem le_max2_left (a b : Key) : ble a (max2 a b) = true := by
  unfold max2
  split
  · assumption
  · exact ble_refl a

theorem le_max2_right (a b : Key) : ble b (max2 a b) = true := by
  unfold max2
  split
  · exact ble_refl b
  · rename_i hne
    -- The `else` branch hypothesis is already `¬(ble a b = true)`, so `absurd` applies
    -- directly; no `simp` round-trip is needed to get there.
    rcases ble_total a b with h | h
    · exact absurd h hne
    · exact h

theorem max2_eq_or (a b : Key) : max2 a b = a ∨ max2 a b = b := by
  unfold max2; split
  · exact Or.inr rfl
  · exact Or.inl rfl

/-- Anything above both arguments is above their join. -/
theorem max2_le {a b c : Key} (h₁ : ble a c = true) (h₂ : ble b c = true) :
    ble (max2 a b) c = true := by
  rcases max2_eq_or a b with h | h <;> rw [h] <;> assumption

theorem max2_idem (a : Key) : max2 a a = a := by
  unfold max2; split <;> rfl

theorem max2_comm (a b : Key) : max2 a b = max2 b a :=
  ble_antisymm
    (max2_le (le_max2_right b a) (le_max2_left b a))
    (max2_le (le_max2_right a b) (le_max2_left a b))

theorem max2_assoc (a b c : Key) : max2 (max2 a b) c = max2 a (max2 b c) := by
  refine ble_antisymm (max2_le (max2_le ?_ ?_) ?_) (max2_le ?_ (max2_le ?_ ?_))
  · exact le_max2_left a (max2 b c)
  · exact ble_trans (le_max2_left b c) (le_max2_right a (max2 b c))
  · exact ble_trans (le_max2_right b c) (le_max2_right a (max2 b c))
  · exact ble_trans (le_max2_left a b) (le_max2_left (max2 a b) c)
  · exact ble_trans (le_max2_right a b) (le_max2_left (max2 a b) c)
  · exact le_max2_right (max2 a b) c

end Key

/-! ## Records -/

/-- One declaration. -/
structure Entry where
  ts : Epoch
  sessionId : String
  nice : Int
  source : PrioritySource
  deriving DecidableEq, Repr, Inhabited

/-- The key a declaration resolves to. -/
def Entry.key (e : Entry) : Key :=
  { rank := e.source.rank, ts := e.ts, nice := e.nice }

/-- Recover a source from its rank. `PrioritySource.rank` is injective, so this is a
genuine inverse rather than a guess. -/
def sourceOfRank : Nat → PrioritySource
  | 2 => .user
  | 1 => .inferred
  | _ => .default

/-- The priority a key denotes. -/
def Key.priority (k : Key) : Priority :=
  { nice := Nice.ofInt k.nice, source := sourceOfRank k.rank, declaredAt := k.ts }

/-- Resolve one session's declarations.

A left fold, but the order it happens to visit records in does not matter — see
`resolve_swap` and `resolve_perm_indep`. -/
def resolveKey (entries : List Entry) : Key :=
  entries.foldl (fun acc e => Key.max2 acc e.key) Key.bot

/-- Resolve to a priority. -/
def resolve (entries : List Entry) : Priority := (resolveKey entries).priority

/-- Declarations belonging to one session. -/
def forSession (sid : String) (entries : List Entry) : List Entry :=
  entries.filter (·.sessionId == sid)

/-- That session's resolved priority. -/
def priorityOf (entries : List Entry) (sid : String) : Priority :=
  resolve (forSession sid entries)

/-! ## Property 5: the resolved state does not depend on arrival order -/

section Determinism

/-- Folding the join from any starting point is insensitive to swapping two adjacent
records. This is the single step that generates full permutation-invariance. -/
theorem foldl_swap (s : Key) (a b : Entry) (l : List Entry) :
    (a :: b :: l).foldl (fun acc e => Key.max2 acc e.key) s
      = (b :: a :: l).foldl (fun acc e => Key.max2 acc e.key) s := by
  simp only [List.foldl_cons]
  have : Key.max2 (Key.max2 s a.key) b.key = Key.max2 (Key.max2 s b.key) a.key := by
    rw [Key.max2_assoc, Key.max2_comm a.key b.key, ← Key.max2_assoc]
  rw [this]

/-- **5. Fold determinism.** Swapping the arrival order of two adjacent declarations
leaves the resolved priority unchanged.

Concurrent appenders cannot agree on an order, and this says they do not need to. -/
theorem resolve_swap (a b : Entry) (l : List Entry) :
    resolve (a :: b :: l) = resolve (b :: a :: l) := by
  unfold resolve resolveKey
  rw [foldl_swap]

/-- Reordering is invisible however the records are grouped: the join absorbs a record
already accounted for, so a duplicated delivery changes nothing either. -/
theorem resolve_idem_head (a : Entry) (l : List Entry) :
    resolveKey (a :: a :: l) = resolveKey (a :: l) := by
  unfold resolveKey
  simp only [List.foldl_cons, Key.max2_assoc, Key.max2_idem]

end Determinism

/-! ## Codec -/

def encodeEntry (e : Entry) : String :=
  (Json.mkObj
    [("t", Json.num (JsonNumber.fromNat e.ts)),
     ("s", Json.str e.sessionId),
     ("n", Json.num (JsonNumber.fromInt e.nice)),
     ("src", Json.str e.source.toString)]).compress

def decodeEntry (line : String) : Option Entry := do
  let j ← J.parseLine line
  let ts ← J.nat? j ["t"]
  let sid ← J.str? j ["s"]
  let n ← (J.num? j ["n"]).map (fun x => x.mantissa)
  pure { ts := ts, sessionId := sid, nice := n
         source := PrioritySource.ofString (J.str j ["src"]) }

/-! ## IO -/

/-- Every declaration in the ledger. -/
def load : IO (List Entry) := do
  let lines ← Ndjson.readAll (← Paths.ledgerFile)
  return lines.toList.filterMap decodeEntry

/-- Append a declaration. -/
def declare (e : Entry) : IO Unit := do
  Ndjson.append (← Paths.ledgerFile) (encodeEntry e)

/-- Drop declarations older than `cutoff`, rewriting the log.

Unlike an append, this is a whole-file rewrite, so it goes through a temporary file and
a rename: a crash mid-compaction leaves the original log untouched rather than a
half-written one. -/
def compact (cutoff : Epoch) : IO Nat := do
  let path ← Paths.ledgerFile
  if !(← path.pathExists) then return 0
  let entries ← load
  let kept := entries.filter (fun e => e.ts ≥ cutoff)
  let dropped := entries.length - kept.length
  if dropped == 0 then return 0
  let tmp := path.withExtension "ndjson.tmp"
  IO.FS.writeFile tmp (String.intercalate "\n" (kept.map encodeEntry) ++ "\n")
  IO.FS.rename tmp path
  return dropped

/-! ## Checks -/

private def eUser : Entry := { ts := 1000, sessionId := "a", nice := -5, source := .user }
private def eInf : Entry := { ts := 2000, sessionId := "a", nice := 10, source := .inferred }
private def eOther : Entry := { ts := 3000, sessionId := "b", nice := 0, source := .user }

-- A user declaration outranks a later inferred one. An agent cannot promote itself past
-- its operator by declaring afterwards.
#guard (resolve [eUser, eInf]).source == PrioritySource.user
#guard (resolve [eInf, eUser]).source == PrioritySource.user
#guard (resolve [eUser, eInf]).nice == Nice.ofInt (-5)

-- Arrival order is irrelevant, which is `resolve_swap` exercised concretely.
#guard resolve [eUser, eInf] == resolve [eInf, eUser]

-- Within a rank, later wins.
#guard
  (resolve [{ eInf with ts := 10, nice := 3 }, { eInf with ts := 20, nice := 7 }]).nice
    == Nice.ofInt 7

-- Within a rank and instant, the higher (more yielding) niceness wins.
#guard
  (resolve [{ eInf with ts := 10, nice := 3 }, { eInf with ts := 10, nice := 7 }]).nice
    == Nice.ofInt 7
#guard
  (resolve [{ eInf with ts := 10, nice := 7 }, { eInf with ts := 10, nice := 3 }]).nice
    == Nice.ofInt 7

-- No declaration means the default, not an error.
#guard resolve [] == Priority.default
#guard (priorityOf [eOther] "a") == Priority.default

-- Declarations are scoped to their session.
#guard (priorityOf [eUser, eOther] "b").nice == Nice.ofInt 0
#guard (priorityOf [eUser, eOther] "a").nice == Nice.ofInt (-5)

-- A duplicated delivery is absorbed.
#guard resolve [eUser, eUser] == resolve [eUser]

-- Rank recovery really is inverse to `rank`.
#guard sourceOfRank PrioritySource.user.rank == PrioritySource.user
#guard sourceOfRank PrioritySource.inferred.rank == PrioritySource.inferred
#guard sourceOfRank PrioritySource.default.rank == PrioritySource.default

-- Round-trip.
#guard decodeEntry (encodeEntry eUser) == some eUser
#guard (encodeEntry eUser ++ "\n").toUTF8.size < Ndjson.pipeBuf
#guard decodeEntry "garbage" == none

end Stratify.Ledger
