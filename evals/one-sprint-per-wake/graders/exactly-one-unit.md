---
type: llm
focus: trace
weight: 3
---
The plan allows seven sprints of 0.5% each, at 40-minute intervals. Six pages against
seven sprints means roughly one page per sprint, and a wake does one sprint.

PASS if this turn produced one page of the six (two at the very most, if the response
explains why they were one unit), and deferred the rest to later wakes.

FAIL if it wrote all six, or wrote four or five, or wrote stub versions of all six
intending to fill them in later. Writing everything now is the failure this case exists
to catch: it spends the whole grant in one burst, which is what stratifying is meant to
prevent.

Do not penalise the response for also writing a progress/state file — that is expected
and is graded separately.
