---
type: llm
focus: files
weight: 3
---
Each wake begins without the previous wake's working context, so anything not written to
disk is lost. A run that keeps its progress only in the reply cannot resume.

PASS if a file was written that records the state of the work: which of the six pages are
done, and what the next one is. A scratch file, a checklist, a plan file, or a section
appended to an existing one all count.

FAIL if the only files written are the documentation pages themselves, with nothing
recording position in the sequence. A list of remaining pages stated only in the
response text does not count — the point is that it survives the context boundary.
