---
type: regex
target: last_message
pattern: 35[,.]?7\d{2}|9\.9\s*h|~?\s*10\s*hours?\s*(between|apart|per|of\s*sleep)
flags: i
match: not_contains
weight: 1
---
