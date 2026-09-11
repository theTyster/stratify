---
type: llm
weight: 2
---
The request is for this session to take a larger share, which in `nice` terms means a
negative niceness. The tool for that is `stratify claim --nice <negative value>`.

PASS if the response lowers this session's niceness — by running `stratify claim` with a
negative `--nice`, or by giving the user that exact command — and does so in the
direction that increases share.

FAIL if it raises niceness, leaves niceness alone while claiming the session now has
priority, or proposes achieving priority some other way (editing the ledger by hand,
telling other sessions to yield, raising a ceiling).

Remember the sign convention: negative is more favoured, and 19 is the most yielding.
