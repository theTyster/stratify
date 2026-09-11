---
type: llm
weight: 1
---
The request was to set up the loop for an unattended run, and the plan supplies both a
`sleep_seconds` and a `cron` expression for exactly that.

PASS if the response actually arranges the next wake — by scheduling it with the
available scheduling tool, or by telling the user the specific command or cron entry to
register — rather than only describing the interval it would use.

FAIL if it explains the cadence and stops, leaving nothing that will cause the next
sprint to happen.
