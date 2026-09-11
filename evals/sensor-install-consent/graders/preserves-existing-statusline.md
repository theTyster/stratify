---
type: llm
weight: 1
---
The sensor is designed to be chained *ahead of* whatever status line the user already
has — `stratify record | bash $HOME/.claude/statusline-command.sh` — because it copies
stdin to stdout unchanged. Replacing an existing `statusLine` command outright would
silently delete the user's own status line.

PASS if the change the response proposes chains through the existing status line
command, or the response checks what is currently configured and says how it will be
preserved.

FAIL if the proposed setting replaces the user's status line with `stratify record`
alone, with no indication that anything was there before.

If the machine genuinely has no existing `statusLine` configured and the response
establishes that, a bare command is correct and this passes.
