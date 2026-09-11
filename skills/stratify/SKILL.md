---
name: stratify
description: Pace long-running autonomous work against Claude's shared rate-limit window. Use when the user asks to work in stratified sprints, run at a lower priority, avoid exhausting session limits, continue across a window reset, or inspect the remaining 5-hour or 7-day allowance and the sessions consuming it.
allowed-tools: Bash(stratify:*), CronCreate, CronDelete, CronList, ScheduleWakeup, AskUserQuestion
---

# stratify

Claude sessions share one rate-limit window. Heavy usage in any one of them starves the
others and exhausts the window long before it resets.

`stratify` is `nice` for that shared resource. It tells this session how much of the
window it may use, how much work fits in one sprint, and how long to wait between
sprints.

**Do not compute allocations yourself.** The binary computes them and carries proofs
that they cannot oversubscribe the window. Follow its output. If a value looks wrong,
report the concern rather than substituting your own arithmetic.

## The one thing to know first

`used_percentage` and `resets_at` are not stored on disk anywhere. They exist only in
the statusline payload, so `stratify` needs its sensor installed to read window state at
all. Without it, session counts and token attribution are still real; window usage and
reset timing are simply unavailable.

Check `sensor_installed` in any JSON output. If it is `false`:

1. Run `stratify install-sensor`. **This only prints the change — it modifies nothing.**
2. Show the user the printed settings block.
3. Ask before applying it. Applying means editing `~/.claude/settings.json`, which
   affects every Claude session, so it needs explicit permission.

## Workflow

### 1. Inspect the current state

```bash
stratify status
```

Reports active CLI and Cowork sessions, each session's model, current window usage, and
time remaining before reset. Use it when the user asks what is running, which sessions
are consuming the allowance, or how much of the limit is left.

### 2. Get this session's allowance

```bash
stratify plan
```

Returns JSON, and defaults to the current session id.

| Field | Meaning |
|---|---|
| `binding_window` | The limiting window: `five_hour` or `seven_day`. The weekly one is often the constraint. |
| `grant_percentage` | This session's share of the remaining window headroom. |
| `sprint_budget_percentage` | The most one sprint may consume. |
| `sprints_remaining` | How many sprints the grant divides into. |
| `sleep_seconds` | How long to wait before the next sprint. |
| `cron` | The same cadence as a cron expression. |
| `wait_for_reset` | `true` means the budget is exhausted. Do not begin another sprint. |
| `provenance` | `measured` = a real reading. `estimated` = inferred from a stale one. `UNKNOWN` = no data. |
| `claimants` | How many sessions the window is split across. |

Never present an `estimated` or `UNKNOWN` value as a measurement. Say which it is.

### 3. Set priority when the user requests it

```bash
stratify claim --nice 10    # yield share to other sessions
stratify claim --nice -5    # take a larger share
```

Niceness runs from `-20` (most favoured) to `19` (most yielding), following `nice(2)`.
Weight spans 14.9× across that range, so a yielding session still makes steady progress
rather than stalling.

Use the default `inferred` source. The `--user` flag marks a declaration authoritative
and outranks any later inferred one — **that flag is the operator's, not yours.** If the
user says which session should have priority, give them the command to run:

```bash
stratify claim --nice <value> --user
```

If this session already has a recorded user declaration, `plan` honours it and ignores a
conflicting `--nice`. That is intended; do not work around it.

### 4. Fit the work to the sprint budget

Break the task into units that each fit `sprint_budget_percentage`, and complete
**exactly one sprint per wake**. End each sprint at a natural checkpoint:

- one file written;
- one section completed;
- one test suite run; or
- one clearly bounded investigation finished.

Keep a short written progress note — a scratch file, or the plan file if one exists —
recording what is done, any findings or failures, and the next action. Each wake starts
without the previous wake's working context, so anything not written down is lost.

### 5. Schedule the next wake

**Inside `/loop`** — use `ScheduleWakeup` with the current `sleep_seconds`, which
recomputes the plan every iteration:

```text
ScheduleWakeup({
  delaySeconds: <sleep_seconds>,
  prompt: <same /loop input>,
  reason: "7d window at 58%, grant 3.7%, 13 claimants"
})
```

**Long unattended runs** — use `CronCreate` with the returned `cron` expression. Two
limits apply: recurring jobs expire after 7 days, and they fire only while the session is
idle. Tell the user about the 7-day expiry whenever you create one.

Either way, re-run `stratify plan` every `resample_every_sprints` sprints (default 4).
Never rely on a cached plan: an allocation computed against 3 claimants is wrong once 13
sessions are sharing the window.

### 6. Wait for a reset when required

When `wait_for_reset` is `true`, do not begin a sprint. Schedule the next wake past
`seconds_left` and stop. After the reset, re-run `stratify plan` and continue — nothing
else is needed, which is another reason to re-sample rather than cache.

## Housekeeping

```bash
stratify gc    # drop log records older than 8 days
```

## Honesty requirements

These are not style notes; they are the point of the tool.

- **Separate evidence from judgement.** "`stratify` reports the 7-day window at 58%" is
  evidence. "You have plenty of headroom" is a judgement — leave it to the user.
- **Do not guess when the sensor is absent.** State that window usage and reset timing
  are unavailable.
- **Report incomplete work.** If a sprint was skipped, ended early, or failed its
  planned unit, say so at the next wake. A run that reports failure beats one that
  silently stops.
- **Read `claimants` correctly.** It counts sessions that *could* spend, including idle
  ones. Excluding an idle session would starve it the moment it woke.
