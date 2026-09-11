# stratify evals

Two halves, because the thing being built has two halves.

| | What it checks | Runs today? |
|---|---|---|
| `run-checks.sh` | The binary. Does the allocator compute the right thing, does the sensor stay out of the way, does anything get written where it shouldn't? | **Yes** |
| `<case>/prompt.md` + `graders/` | The skill. Given correct numbers, does the agent *use* them correctly? | Only with `claude plugin eval` |

Everything in the first column has a single right answer that a shell script can assert.
Everything in the second is a judgement about behaviour and needs a model to grade it.
Mixing them would mean the mechanical facts could only be checked by paying for an
LLM-graded run.

## Running the deterministic checks

```bash
evals/run-checks.sh              # builds first
evals/run-checks.sh --no-build   # against an already-built binary
STRATIFY_BIN=/path/to/stratify evals/run-checks.sh --no-build
```

Exit status is 0 only if every check passed.

Each check runs against a scratch `$HOME` and a scratch `$STRATIFY_HOME`, so the session
registry, the Cowork store and the runtime state are all empty and controlled. Nothing
reads or writes anything under your real `~/.claude`. Window state is injected by
writing a `samples.ndjson` line directly, which is how the stale-reading and
rolled-over-window cases are reachable at all — you cannot wait five hours inside a test.

What it covers, in the order the script runs it:

- **Build and sources** — `lake build` (which elaborates every `#guard` fixture), no
  `sorry`, no `Float` used anywhere.
- **Axiom hygiene and non-vacuity** — via `proofs/Axioms.lean`; see below.
- **Eval case files** — `validate-cases.py`; see below.
- **The sensor** — byte-identical passthrough, exit 0 on unparseable input, records
  inside the 512-byte atomic-append bound, 600 concurrent appends with nothing torn.
- **Degraded mode** — no sensor means `UNKNOWN`, not a guess; `install-sensor` is
  verified to modify nothing on disk.
- **Provenance** — a reading older than the window it describes reports `estimated`.
- **Binding window** — the lower permitted burn rate wins, in both directions.
- **Exhaustion and rollover** — no grant past the ceiling; full ceiling and a nominal
  runway once the observed reset time has passed.
- **Liveness** — a live Claude-like process counts; a recycled pid does not; a live
  non-Claude process does not; an unprobeable registry fails safe to all-alive.
- **The six properties**, against the compiled binary rather than the proofs: grants
  sum within budget, niceness is monotone and clamped, the sprint sequence stays inside
  the grant, sleep stays in `[60, 3600]` across 24 input combinations, the ledger
  resolves the same in either arrival order, `--user` outranks a later `--nice`.
- **Blast radius** — after running every command, nothing was written under `$HOME` and
  only the two log files exist under `$STRATIFY_HOME`.

### `proofs/Axioms.lean`

Run by `run-checks.sh` via `lake env lean`. Two jobs.

`#print axioms` on each of the twelve properties, so a `sorry` cannot hide behind a
green build. The expected footing is Lean's three standard axioms — `propext`,
`Quot.sound`, `Classical.choice`. The arithmetic properties need only the first two; the
ledger-determinism ones reach `Classical.choice` through `omega`, which uses it to prove
a goal-side disjunction. The assertion that carries information is that no *custom*
axiom appears.

Then non-vacuity witnesses, because a conditional property whose hypotheses are
unsatisfiable is true and useless. `grant_pos` is conditional on `total ≤ budget · w`;
`clampSleep_bounds` on `minSleep ≤ maxSleep`; `budgetOf_rolledOver` on the window having
rolled over. Each is exhibited at realistic values, along with evidence the bounds are
tight rather than slack: the four grants sum to exactly the budget, both ends of the
sleep clamp are reachable, and a 12.2 % grant divides into 24 real sprints rather than
one empty one.

### `validate-cases.py`

Checks the case directories against the schema `claude plugin eval` actually enforces —
key names, enums, per-grader-type required fields, strict rejection of unknown keys. It
exists because the harness itself cannot run here, and a suite that fails to parse would
otherwise look identical to a suite that had never been tried. It is not a substitute
for running the cases.

## The agent-behaviour cases

```bash
claude plugin eval . --ablation with-without --allow-tools 'Bash(stratify:*)' --json
```

On this account that currently prints `plugin eval` is currently in early access and
does nothing. The cases are written and validated against the schema so they work when
that lifts.

Each case is a directory holding `prompt.md` (frontmatter plus the user turn) and
`graders/*.md` (one grader per file; the filename is the grader's name). Every case also
carries a `skill-fires.md` grader marked `arm: with-only`, which is the harness's
plugin-fired indicator rather than part of the score.

| Case | The failure it exists to catch |
|---|---|
| `reads-allowance` | Guessing a window figure instead of asking the tool for one. |
| `no-hand-arithmetic` | Redoing the planner's division. The emitted interval is clamped, so a hand calculation gives a visibly different answer — about ten hours instead of one. |
| `honest-provenance` | Reporting an `estimated` reading as a measurement. |
| `sensor-absent` | Converting token counts into a window percentage when there is no denominator on disk to divide by. |
| `sensor-install-consent` | Editing `~/.claude/settings.json`, which governs every session, without asking — or replacing the user's existing status line instead of chaining through it. |
| `user-flag-is-operators` | Passing `claim --user` on its own behalf, which defeats the only thing stopping an agent from promoting itself past its operator. |
| `wait-for-reset` | Sprinting on a zero grant, or giving up instead of scheduling past the reset. |
| `one-sprint-per-wake` | Doing all six units now, or leaving no durable note for a wake that starts with no context. |
| `resample-not-cache` | Continuing on an allocation computed against three claimants when thirteen may now be sharing the window. |
| `idle-sessions-count` | Agreeing to exclude idle sessions from the split, which starves them the moment they wake. |

Most cases embed the relevant `stratify` output in the prompt. That is deliberate: it
keeps them testing the skill's behaviour rather than whether the binary happens to be on
`PATH` inside the eval sandbox, and it lets the inputs be pinned to the exact shapes
worth probing — a clamped interval, a stale reading, a zero grant. The two cases that
*should* invoke the tool (`reads-allowance`, `resample-not-cache`) assert that with
`tool_used` graders, which pass on the attempt.

## Standing caveat

All of this is evidence production. `run-checks.sh` reports what it ran and what it
observed; the cases, when they can run, will report scores. Whether that evidence is
sufficient to call the implementation verified is the operator's decision, not the
suite's.
