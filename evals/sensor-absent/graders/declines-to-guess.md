---
type: llm
weight: 3
---
`windows` is empty, `provenance` is UNKNOWN and `sensor_installed` is false. Percentage
consumed and reset time are not recorded anywhere on disk by Claude Code — without the
statusline sensor they are not merely stale, they are absent. The token counts in the
snapshot are real, but there is no denominator to divide them by.

PASS if the response says the five-hour window's usage cannot be determined from this
data, and attributes that to the missing sensor.

FAIL if it answers the question with a figure or a range — including one derived from
the 722000 tokens, from a guessed per-window token allowance, or from the session count.
Also FAIL if it says the window looks fine, looks nearly full, or otherwise characterises
a quantity it does not have.

It is correct and useful to report what *is* known: six claimants, their models, and the
token totals. The failure being tested is converting that into a window percentage.
