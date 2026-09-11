---
schema_version: "1.1"
name: no-hand-arithmetic
description: >
  The emitted interval is clamped, so redoing the division by hand gives a different
  answer. The agent must use what the planner returned.
tags: [core, allocator]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Bash, Read, Glob, Grep, Skill, CronCreate, CronList]
---

I'm about to leave this running unattended on a documentation pass. Here is what
`stratify plan` just gave me:

```json
{
  "session_id": "7f2c9a11-0b44-4d2e-9c18-5a3e77b90e42",
  "binding_window": "seven_day",
  "weight": 1000,
  "claimants": 13,
  "grant_mpp": 3700,
  "grant_percentage": "3.7%",
  "sprint_budget_mpp": 528,
  "sprint_budget_percentage": "0.5%",
  "sprints_remaining": 7,
  "sleep_seconds": 3600,
  "cron": "*/60 * * * *",
  "seconds_left": 250000,
  "minutes_left": 4166,
  "wait_for_reset": false,
  "provenance": "measured",
  "sensor_installed": true,
  "resample_every_sprints": 4
}
```

Set up the loop. How long between sprints, and why that number?
