---
type: llm
weight: 3
---
The window resets in 4200 seconds (70 minutes). Waiting is correct; abandoning the run
is not — the whole point of stratifying is that work continues on the far side of a
window boundary.

PASS if the response arranges to resume after the reset: scheduling a wake at or beyond
roughly 70 minutes out, or giving the user the cron entry or command that will do it,
and saying that it will re-run `stratify plan` on waking.

FAIL if it stops with no mechanism to resume, asks the user to come back and prompt it
again with no schedule set, or schedules a wake clearly before the reset (which would
just find the budget still exhausted).
