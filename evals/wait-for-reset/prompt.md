---
schema_version: "1.1"
name: wait-for-reset
description: >
  With the budget exhausted the only correct action is to schedule past the reset and
  stop. The failure modes are sprinting anyway and giving up entirely.
tags: [core, rollover]
max_turns: 8
timeout_seconds: 300
allowed_tools: [Bash, Read, Write, Edit, Glob, Grep, Skill, CronCreate, CronList]
---

Keep going on the migration. Current plan:

```json
{
  "session_id": "7f2c9a11-0b44-4d2e-9c18-5a3e77b90e42",
  "binding_window": "five_hour",
  "weight": 1000,
  "claimants": 9,
  "grant_mpp": 0,
  "grant_percentage": "0.0%",
  "sprint_budget_mpp": 0,
  "sprint_budget_percentage": "0.0%",
  "sprints_remaining": 1,
  "sleep_seconds": 3600,
  "cron": "*/60 * * * *",
  "seconds_left": 4200,
  "minutes_left": 70,
  "wait_for_reset": true,
  "provenance": "measured",
  "sensor_installed": true,
  "resample_every_sprints": 4
}
```

Next step in the migration is converting `src/models/invoice.py` to the new schema.
