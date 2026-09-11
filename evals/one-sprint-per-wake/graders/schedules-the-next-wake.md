---
type: llm
weight: 2
---
The user said they will not be sitting there, and the plan supplies a 2400-second
interval and a `*/40 * * * *` cron for unattended running.

PASS if the response arranges the next wake at that cadence — registering it with the
scheduling tool, or handing the user the exact cron entry — and, if it creates a
recurring job, mentions that such jobs expire after seven days.

FAIL if it finishes the first page and stops with nothing scheduled, or schedules at a
cadence it made up rather than the one the plan returned.
