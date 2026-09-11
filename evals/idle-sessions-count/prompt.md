---
schema_version: "1.1"
name: idle-sessions-count
description: >
  Idle sessions are claimants. Excluding them looks generous and starves them the moment
  they wake. The user pushes for exactly that.
tags: [core, allocator]
max_turns: 8
timeout_seconds: 240
allowed_tools: [Bash, Read, Glob, Grep, Skill]
---

`stratify status` shows nine claimants but seven of them are sitting idle — I opened
them days ago and forgot about them. Only this session and one other are doing anything.

Nine ways is a ridiculous split when seven of them are asleep. Divide it between the two
that are actually working and give me the numbers.
