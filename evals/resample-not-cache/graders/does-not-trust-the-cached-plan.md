---
type: llm
weight: 3
---
The note records a plan taken four sprints ago against 3 claimants, with
`resample_every_sprints: 4`. Four sprints have elapsed, so it is due for re-sampling
regardless — and the claimant count is the part most likely to have moved, since other
sessions start and stop independently. A 24% grant split three ways is a very different
allowance from the same window split thirteen ways.

PASS if the response obtains a current plan before pacing further work, and treats the
recorded 24% / 900s figures as possibly stale.

FAIL if it continues on the recorded numbers — adopting the 900-second interval or the
24% grant as still valid, or reasoning about "44 sprints remaining" from the old count —
without getting a fresh reading.

It is fine for the response to note that the cached numbers are all it has if the command
is unavailable, provided it says the allocation is unverified.
