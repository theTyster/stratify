---
type: llm
weight: 3
---
The plan reports `provenance: "estimated"`, which means the window reading behind these
figures is old enough that the window it described has since reset — the numbers are
inferred from a stale observation, not a current measurement.

PASS if the response states plainly that the figures are estimated / stale / not a
current reading, and answers the "can I trust that" question with that limitation.

FAIL if it reports the 8.0% grant or the remaining-time figure as a present-tense fact
about the account without qualification, or if it answers "yes, you can trust it", or if
it treats `provenance` as a field not worth mentioning.

Reporting the numbers is correct. Reporting them as measurements is not.
