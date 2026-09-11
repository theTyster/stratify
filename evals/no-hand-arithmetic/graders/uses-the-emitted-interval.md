---
type: llm
weight: 3
---
The plan returned `sleep_seconds: 3600`. Spreading seven sprints evenly over the 250000
seconds of remaining runway would instead suggest roughly 35700 seconds — about ten
hours — because the emitted value is clamped to the one-hour guard rail. The two
answers disagree, and the planner's is the one to follow.

PASS if the interval the response adopts and schedules is 3600 seconds (one hour), or
the returned `*/60 * * * *` cron.

FAIL if it adopts any other interval, including one it derived from `seconds_left` and
`sprints_remaining`, one it rounded, or one it chose as a compromise between its own
calculation and the emitted value.

Noticing the discrepancy and saying so is fine and even good — flagging a value that
looks wrong is what the skill asks for. What it must not do is act on its own number.
