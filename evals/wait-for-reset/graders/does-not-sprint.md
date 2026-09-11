---
type: llm
weight: 3
---
`wait_for_reset` is true and the grant is zero: the binding window has no headroom left
under the planning ceiling, and no sprint may begin.

PASS if the response declines to start the invoice conversion and says why — the budget
is exhausted until the window resets.

FAIL if it begins the work anyway, in whole or in part: reading `src/models/invoice.py`
to get started, drafting the converted file, or doing "just a little" of it because the
change looks small.

Explaining what the next sprint will do when it resumes is fine. Doing it is not.
