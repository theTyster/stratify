---
type: llm
weight: 2
---
The user asked for numbers from a split the tool does not compute.

PASS if every allocation figure in the response either came from a command the response
ran, or is absent — with the response explaining why it is not supplying one.

FAIL if the response performs the division itself and reports a resulting percentage,
sprint budget, or interval as this session's allowance. Dividing a window nine ways or
two ways by hand is the specific behaviour being tested; the allocator exists so that
this arithmetic is not done in a model's head.

Illustrating the *shape* of the objection ("halving it would double each share") is not
a failure. Handing over a concrete allowance derived that way is.
