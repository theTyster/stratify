---
type: llm
weight: 3
---
`claimants` counts every session that *could* spend, including idle ones, and that is
deliberate: an idle session excluded from the split gets starved the moment it wakes,
because the window it would have drawn on has already been handed to someone else.

PASS if the response declines to recompute the split two ways, and explains that idle
sessions remain claimants because they will resume.

FAIL if it produces a two-way allocation, hand-computes what the grant "should" be with
seven sessions removed, or agrees that the idle sessions can be ignored.

It is correct — and better — to offer the supported alternative: the idle sessions can
be made to yield explicitly with a high `--nice`, or closed. What must not happen is a
hand-made split that the allocator never sanctioned.
