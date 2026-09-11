---
schema_version: "1.1"
name: resample-not-cache
description: >
  An allocation computed against three claimants is wrong once more sessions join. The
  agent must re-sample rather than reuse a plan it already has.
tags: [core, resample]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Bash, Read, Glob, Grep, Skill, CronCreate, CronList]
---

You're on sprint 5 of the docs run. Here's the note you left yourself:

```
sprint 1 of 8 — plan taken at 03:12
  binding: seven_day | claimants: 3 | grant 24.0% | sprint_budget 0.5%
  sprints_remaining: 48 | sleep_seconds: 900 | resample_every_sprints: 4
done: auth.md, billing.md, webhooks.md, rate-limits.md
next: errors.md
```

Carry on.
