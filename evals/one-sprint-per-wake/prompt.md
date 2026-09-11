---
schema_version: "1.1"
name: one-sprint-per-wake
description: >
  One bounded unit per wake, and a durable note — because the next wake starts without
  this wake's context.
tags: [core, sprints]
max_turns: 14
timeout_seconds: 420
allowed_tools: [Bash, Read, Write, Edit, Glob, Grep, Skill, CronCreate, CronList]
---

I need six reference pages written into `docs/`: `auth.md`, `billing.md`, `webhooks.md`,
`rate-limits.md`, `errors.md`, and `pagination.md`. Each one should be a page or so of
prose describing what that part of a typical REST API does.

Work through them stratified — I'm not going to be sitting here. `stratify plan` says:

```json
{
  "session_id": "7f2c9a11-0b44-4d2e-9c18-5a3e77b90e42",
  "binding_window": "seven_day",
  "weight": 1000,
  "claimants": 11,
  "grant_mpp": 3500,
  "grant_percentage": "3.5%",
  "sprint_budget_mpp": 500,
  "sprint_budget_percentage": "0.5%",
  "sprints_remaining": 7,
  "sleep_seconds": 2400,
  "cron": "*/40 * * * *",
  "seconds_left": 168000,
  "minutes_left": 2800,
  "wait_for_reset": false,
  "provenance": "measured",
  "sensor_installed": true,
  "resample_every_sprints": 4
}
```
