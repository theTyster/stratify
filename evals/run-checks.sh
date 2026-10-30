#!/usr/bin/env bash
# Deterministic checks for the `stratify` binary.
#
# These are the mechanical half of the eval suite: every assertion here has a single
# right answer that does not depend on a model's judgement, on this machine's live
# session population, or on the wall clock. The other half — whether an agent *follows*
# the skill — lives in the case directories beside this file and needs `claude plugin
# eval`.
#
# Hermetic by construction. Every check runs against a scratch $HOME (so the session
# registry and the Cowork store are empty and controlled) and a scratch $STRATIFY_HOME
# (so nothing touches real scheduling state). Nothing here reads or writes anything
# under your real ~/.claude.
#
# Usage:
#   evals/run-checks.sh            # build, then check
#   evals/run-checks.sh --no-build # check an already-built binary
#   STRATIFY_BIN=/path/to/stratify evals/run-checks.sh --no-build
#
# Exit status is 0 only if every check passed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LEAN="$REPO/lean"
BIN="${STRATIFY_BIN:-$LEAN/.lake/build/bin/stratify}"
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stratify-checks.XXXXXX")"

# macOS ships bash 3.2, so state that would naturally be an array is kept as a
# whitespace-separated string: no `mapfile`, and no `set -u` trouble when empty.
STUB_PIDS=""
cleanup() {
  for p in $STUB_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'
else G=""; R=""; B=""; D=""; Z=""; fi

N_PASS=0
N_FAIL=0
FAILURES=""

section() { printf '\n%s%s%s\n' "$B" "$1" "$Z"; }
ok()      { N_PASS=$((N_PASS + 1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; }
bad() {
  N_FAIL=$((N_FAIL + 1))
  FAILURES="$FAILURES  - $1
"
  printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"
  [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$Z"
  return 0
}
# chk <label> <actual> <expected>
chk() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}
# chk_le <label> <a> <b>  -- passes when a <= b
chk_le() {
  if [ "$2" -le "$3" ] 2>/dev/null; then ok "$1 ($2 <= $3)"
  else bad "$1" "expected $2 <= $3"; fi
}
# chk_in <label> <value> <lo> <hi>
chk_in() {
  if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] 2>/dev/null; then ok "$1 ($2 in [$3,$4])"
  else bad "$1" "expected $3 <= $2 <= $4"; fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Read one dotted path out of a JSON document on stdin. Booleans print as
# true/false so they compare as shell strings.
jget() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if k.lstrip("-").isdigit() else d[k]
print(str(d).lower() if isinstance(d, bool) else d)
' "$1"
}

# A statusline payload. mkpayload SID [<window>:<used%>:<resets_at>]...
mkpayload() {
  python3 -c '
import json, sys
payload = {
    "session_id": sys.argv[1],
    "model": {"id": "claude-opus-5"},
    "effort": {"level": "high"},
    "context_window": {"total_input_tokens": 15500, "total_output_tokens": 1200},
    "cost": {"total_cost_usd": 0.1234},
}
limits = {}
for spec in sys.argv[2:]:
    kind, used, resets = spec.split(":")
    limits[kind] = {"used_percentage": float(used), "resets_at": int(resets)}
if limits:
    payload["rate_limits"] = limits
sys.stdout.write(json.dumps(payload))
' "$@"
}

# A fresh hermetic environment. Echoes its root.
new_env() {
  local root="$WORK/$1"
  mkdir -p "$root/home/.claude/sessions" "$root/state" "$root/bin"
  printf '%s' "$root"
}

# Run the binary inside one. sx <root> <args...>
sx() {
  local root="$1"; shift
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      HOME="$root/home" STRATIFY_HOME="$root/state" "$BIN" "$@"
}

# Write a session-registry entry. mkreg <root> <pid> <sid> <name> <status> <procStart>
mkreg() {
  python3 -c '
import json, sys
root, pid, sid, name, status, proc_start = sys.argv[1:7]
path = f"{root}/home/.claude/sessions/{pid}.json"
open(path, "w").write(json.dumps({
    "pid": int(pid), "sessionId": sid, "cwd": f"/tmp/eval-{pid}",
    "name": name, "status": status, "procStart": proc_start,
    "version": "2.1.268", "updatedAt": 1789102605342,
}))
' "$@"
}

# N pids that do not exist, so `ps` can say nothing about them.
dead_pids() {
  python3 -c '
import os, sys
want, found, pid = int(sys.argv[1]), [], 99000
while len(found) < want and pid > 40000:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        found.append(pid)
    except PermissionError:
        pass          # exists, owned by someone else
    pid -= 1
print("\n".join(str(p) for p in found))
' "$1"
}

# A live process whose `ps -o comm=` contains "claude". A symlink to /bin/sleep keeps
# the real binary's code signature intact (a copy is refused by the kernel on macOS)
# while presenting the link's own path as the command name.
#
# Sets $STUB_PID rather than echoing it: a command substitution would run the append to
# $STUB_PIDS in a subshell and the cleanup trap would never see the process.
STUB_PID=""
spawn_stub() {
  local root="$1" n="$2"
  local path="$root/bin/claude-eval-stub-$n"
  ln -sf /bin/sleep "$path"
  nohup "$path" 120 >/dev/null 2>&1 &
  STUB_PID=$!
  STUB_PIDS="$STUB_PIDS $STUB_PID"
  # Off the job table, so the cleanup trap's kill does not print a "Terminated"
  # notification over the summary.
  disown "$STUB_PID" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
section "Build and elaboration-time checks"
# ---------------------------------------------------------------------------

if [ "$DO_BUILD" = 1 ]; then
  if (cd "$LEAN" && lake build >"$WORK/build.log" 2>&1); then
    ok "lake build clean (every #guard in the sources elaborated)"
  else
    bad "lake build" "see $WORK/build.log"
    tail -20 "$WORK/build.log"
  fi
else
  ok "build skipped (--no-build)"
fi

if [ -x "$BIN" ]; then ok "binary present at ${BIN#"$REPO"/}"
else bad "binary present" "$BIN is missing or not executable"; fi

# ---------------------------------------------------------------------------
section "Source-level invariants"
# ---------------------------------------------------------------------------

# The proofs are what make the allocator's properties claims rather than hopes; a
# `sorry` anywhere would silently void one.
if grep -rn --include='*.lean' -E '\bsorry\b' "$LEAN/Stratify" "$LEAN/Main.lean" >/dev/null 2>&1; then
  bad "no sorry in sources" "$(grep -rln --include='*.lean' -E '\bsorry\b' "$LEAN/Stratify")"
else
  ok "no sorry in sources"
fi

# Float is kernel-opaque: `decide` cannot reduce it and none of the properties could be
# proved about it. Its absence is load-bearing, so it is asserted rather than assumed.
#
# Matched as code rather than as the word: the sources discuss at length why Float is
# not used, and a bare /\bFloat\b/ flags that prose.
FLOAT_RE='(:|\(|\[|,|→|->)[[:space:]]*Float\b|\bFloat\.|\b(to|of)Float\b'
if grep -rnE --include='*.lean' "$FLOAT_RE" "$LEAN/Stratify" "$LEAN/Main.lean" >/dev/null 2>&1; then
  bad "no Float in sources" "$(grep -rnE --include='*.lean' "$FLOAT_RE" "$LEAN/Stratify" "$LEAN/Main.lean")"
else
  ok "no Float used in sources (all arithmetic is exact fixed-point Nat)"
fi

# ---------------------------------------------------------------------------
section "Axiom hygiene and non-vacuity"
# ---------------------------------------------------------------------------

if (cd "$LEAN" && lake env lean "$REPO/evals/proofs/Axioms.lean" >"$WORK/axioms.log" 2>&1); then
  ok "evals/proofs/Axioms.lean elaborates (non-vacuity witnesses hold)"
  n_thms=$(grep -c 'depends on axioms' "$WORK/axioms.log" | tr -d ' ')
  chk "all twenty properties reported an axiom set" "$n_thms" "20"
  if grep -q 'sorryAx' "$WORK/axioms.log"; then
    bad "no sorryAx" "$(grep sorryAx "$WORK/axioms.log")"
  else
    ok "no sorryAx in any property's axiom set"
  fi
  # Lean's three standard axioms are expected. Anything else would mean a property was
  # postulated rather than proved, which is a different kind of claim entirely.
  unexpected=$(grep 'depends on axioms' "$WORK/axioms.log" \
    | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | tr -d ' ' | sort -u \
    | grep -v -x -e 'propext' -e 'Quot.sound' -e 'Classical.choice' -e '')
  if [ -z "$unexpected" ]; then
    ok "no axiom outside Lean's standard three (propext, Quot.sound, Classical.choice)"
  else
    bad "a custom axiom is in the footing" "$(printf '%s' "$unexpected" | tr '\n' ' ')"
  fi
else
  bad "evals/proofs/Axioms.lean" "see $WORK/axioms.log"
  tail -20 "$WORK/axioms.log"
fi

# ---------------------------------------------------------------------------
section "Eval case files"
# ---------------------------------------------------------------------------

# `claude plugin eval` is behind early access here, so the agent-behaviour cases cannot
# be run. Validating them against the harness's own schema at least establishes that
# they are well-formed rather than quietly unparseable.
if python3 "$REPO/evals/validate-cases.py" "$REPO/evals" >"$WORK/cases.log" 2>&1; then
  ok "$(cat "$WORK/cases.log")"
else
  bad "eval cases do not validate" "$(cat "$WORK/cases.log")"
fi

# ---------------------------------------------------------------------------
section "Sensor: the statusline must be unharmed"
# ---------------------------------------------------------------------------

NOW=$(date +%s)
SID="11111111-1111-4111-8111-111111111111"

E=$(new_env sensor)
mkpayload "$SID" "five_hour:41.2:$((NOW + 14400))" "seven_day:58.0:$((NOW + 400000))" \
  >"$E/payload.json"

sx "$E" record <"$E/payload.json" >"$E/out.json" 2>"$E/err.txt"
chk "record exits 0" "$?" "0"
if cmp -s "$E/payload.json" "$E/out.json"; then
  ok "record passes stdin to stdout byte-identically"
else
  bad "record passthrough" "stdout differs from stdin"
fi

# Claude Code kills an in-flight statusline script and feeds it whatever it feeds it. A
# sensor that breaks the pipe on bad input breaks the user's status line.
printf 'not json at all' >"$E/garbage.txt"
sx "$E" record <"$E/garbage.txt" >"$E/garbage.out" 2>/dev/null
chk "record exits 0 on unparseable input" "$?" "0"
if cmp -s "$E/garbage.txt" "$E/garbage.out"; then
  ok "record passes unparseable input through unchanged"
else
  bad "record garbage passthrough" "stdout differs from stdin"
fi

# A payload with no window reading is logged as a heartbeat.
#
# This assertion is the reverse of what it was. Claude Code drops each window from the
# payload once its `resets_at` passes, so "no rate_limits" is the steady state between a
# reset and the next reading — on this account it lasted over two hours. Skipping those
# renders froze the sensor log and made a healthy sensor indistinguishable from an
# absent one. The heartbeat is the only evidence that the sensor ran and saw nothing.
mkpayload "$SID" >"$E/nowin.json"
sx "$E" record <"$E/nowin.json" >/dev/null 2>&1
chk "a payload with no rate_limits is logged as a heartbeat" \
  "$(wc -l <"$E/state/samples.ndjson" | tr -d ' ')" "2"
if grep -q '"u5"\|"u7"\|"us"' <(tail -1 "$E/state/samples.ndjson"); then
  bad "heartbeat carries no window" "the windowless record has a window field"
else
  ok "and the heartbeat carries no window reading"
fi

# Atomicity depends on one write(2) staying under PIPE_BUF.
longest=$(awk '{ print length($0) + 1 }' "$E/state/samples.ndjson" | sort -rn | head -1)
chk_le "every sample record fits the atomic-append bound" "$longest" "512"

# ---------------------------------------------------------------------------
section "Sensor: concurrency"
# ---------------------------------------------------------------------------

E=$(new_env conc)
WRITERS=40
PER=15
for i in $(seq 1 "$WRITERS"); do
  (
    for _ in $(seq 1 "$PER"); do
      mkpayload "$(printf '%08d-0000-4000-8000-000000000000' "$i")" \
        "five_hour:41.2:$((NOW + 14400))" | sx "$E" record >/dev/null 2>&1
    done
  ) &
done
wait

expected=$((WRITERS * PER))
lines=$(wc -l <"$E/state/samples.ndjson" | tr -d ' ')
chk "$expected concurrent appends all landed" "$lines" "$expected"
malformed=$(python3 -c '
import json, sys
bad = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception:
        bad += 1
print(bad)
' "$E/state/samples.ndjson")
chk "no torn or interleaved records" "$malformed" "0"

# ---------------------------------------------------------------------------
section "Degraded mode: no sensor, no invention"
# ---------------------------------------------------------------------------

E=$(new_env nosensor)
sx "$E" status --json >"$E/status.json" 2>/dev/null
chk "status provenance is UNKNOWN"   "$(jget provenance      <"$E/status.json")" "UNKNOWN"
chk "status sensor_installed false"  "$(jget sensor_installed <"$E/status.json")" "false"
chk "status reports no windows"      "$(jget windows          <"$E/status.json")" "[]"
chk "status finds no claimants"      "$(jget claimants        <"$E/status.json")" "0"

sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "plan provenance is UNKNOWN"     "$(jget provenance      <"$E/plan.json")" "UNKNOWN"
chk "plan sensor_installed false"    "$(jget sensor_installed <"$E/plan.json")" "false"
# It still emits a usable schedule — flagged UNKNOWN — rather than refusing to plan.
chk_in "plan still emits a bounded sleep" "$(jget sleep_seconds <"$E/plan.json")" 60 3600

# `install-sensor` is documented as printing only. That is a promise about someone's
# global settings, so it is checked rather than trusted.
tree_hash() { find "$1" "$2" -type f -exec shasum {} + 2>/dev/null | sort | shasum; }
before=$(tree_hash "$E/home" "$E/state")
sx "$E" install-sensor >"$E/install.txt" 2>&1
after=$(tree_hash "$E/home" "$E/state")
chk "install-sensor modifies nothing on disk" "$after" "$before"
if grep -q 'statusLine' "$E/install.txt" && grep -q 'refreshInterval' "$E/install.txt"; then
  ok "install-sensor prints the settings block"
else
  bad "install-sensor output" "no statusLine/refreshInterval block printed"
fi

# ---------------------------------------------------------------------------
section "Window readings: provenance follows age"
# ---------------------------------------------------------------------------

# A reading older than the shortest window it describes is no longer an observation of
# the current window. Calling it "measured" would be a false claim.
E=$(new_env stale)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u7":58000,"r7":%d}\n' \
  "$((NOW - 6 * 3600))" "$SID" "$((NOW + 3 * 86400))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "a 6h-old reading is reported estimated" "$(jget provenance <"$E/plan.json")" "estimated"
chk "and the window it describes still binds" "$(jget binding_window <"$E/plan.json")" "seven_day"

E=$(new_env fresh)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u7":58000,"r7":%d}\n' \
  "$((NOW - 30))" "$SID" "$((NOW + 3 * 86400))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "a 30s-old reading is reported measured" "$(jget provenance <"$E/plan.json")" "measured"
# A recent sample means the sensor is *running*. Whether it is *installed* is a separate
# question with a separate answer, read from settings.json. Deriving one from the other
# is what had `status` advising the user to install a sensor that was already running.
chk "and a recent sample means the sensor is live" "$(jget sensor_live <"$E/plan.json")" "true"
chk "but installation is not inferred from it" \
  "$(jget sensor_installed <"$E/plan.json")" "false"

# With the shim actually in settings.json, installation reports true — and does so on
# the strength of the settings file, not of any reading.
E=$(new_env installed)
printf '{"statusLine":{"type":"command","command":"stratify record | bash x.sh","refreshInterval":15}}\n' \
  >"$E/home/.claude/settings.json"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "the shim in settings.json reports installed" \
  "$(jget sensor_installed <"$E/plan.json")" "true"
chk "with no samples the sensor is not live"  "$(jget sensor_live <"$E/plan.json")" "false"
chk "and the window is still UNKNOWN"          "$(jget provenance  <"$E/plan.json")" "UNKNOWN"

# ---------------------------------------------------------------------------
section "Binding window selection"
# ---------------------------------------------------------------------------

# The weekly window is usually the real constraint on a busy account; planning against
# the 5-hour window alone would under-constrain. 5h: 85% headroom over 4h. 7d: 5%
# headroom over 5 days. The lower permitted burn rate wins.
E=$(new_env binding)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":5000,"r5":%d,"u7":85000,"r7":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" "$((NOW + 5 * 86400))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "the tighter burn rate binds" "$(jget binding_window <"$E/plan.json")" "seven_day"

# And the reverse, so the choice is not hard-coded to the weekly window. It takes a
# nearly-exhausted five-hour window to out-bind a fresh weekly one: at 85% used over
# four hours the 5h window still permits 0.35 mpp/s against the 7d window's 0.20, which
# is why the first case above lands on seven_day. At 89.5% it permits 0.035 and binds.
E=$(new_env binding5)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":89500,"r5":%d,"u7":5000,"r7":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" "$((NOW + 5 * 86400))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "the 5-hour window binds when it is the tighter one" \
  "$(jget binding_window <"$E/plan.json")" "five_hour"

# ---------------------------------------------------------------------------
section "Exhaustion and rollover"
# ---------------------------------------------------------------------------

# Past the ceiling there is no budget, and the only correct action is to wait.
E=$(new_env exhausted)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":95000,"r5":%d}\n' \
  "$NOW" "$SID" "$((NOW + 3600))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "95% used yields no grant"      "$(jget grant_mpp      <"$E/plan.json")" "0"
chk "and sets wait_for_reset"       "$(jget wait_for_reset <"$E/plan.json")" "true"
chk_in "sleep stays bounded even so" "$(jget sleep_seconds  <"$E/plan.json")" 60 3600

# Once the observed reset time has passed, the budget is fresh and work continues. This
# is the "after five hours it keeps going" requirement, with no special case anywhere.
E=$(new_env rollover)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":95000,"r5":%d}\n' \
  "$((NOW - 60))" "$SID" "$((NOW - 30))" >"$E/state/samples.ndjson"
sx "$E" plan --session "$SID" >"$E/plan.json" 2>/dev/null
chk "a rolled-over window restores the full ceiling" "$(jget grant_mpp <"$E/plan.json")" "90000"
chk "and clears wait_for_reset"  "$(jget wait_for_reset <"$E/plan.json")" "false"
chk "and reports the nominal runway rather than zero" \
  "$(jget seconds_left <"$E/plan.json")" "18000"

# ---------------------------------------------------------------------------
section "Liveness: who counts as a claimant"
# ---------------------------------------------------------------------------

# A live process whose command looks like Claude and whose start time matches the
# registry is a claimant.
E=$(new_env live)
spawn_stub "$E" 1
P="$STUB_PID"
sleep 0.4
LSTART=$(ps -o lstart= -p "$P" | sed -E 's/^ +//; s/ +$//')
if [ -n "$LSTART" ]; then
  mkreg "$E" "$P" "aaaaaaaa-0000-4000-8000-000000000000" "live-one" "busy" "$LSTART"
  sx "$E" status --json >"$E/status.json" 2>/dev/null
  chk "a live claude-like process is counted" "$(jget claimants <"$E/status.json")" "1"

  # Pid reuse: same pid, a start time that does not match what was recorded.
  mkreg "$E" "$P" "aaaaaaaa-0000-4000-8000-000000000000" "live-one" "busy" \
    "Mon Jan  5 01:02:03 2026"
  sx "$E" status --json >"$E/status.json" 2>/dev/null
  chk "a recycled pid with a mismatched start time is not counted" \
    "$(jget claimants <"$E/status.json")" "0"
else
  bad "stub process setup" "ps reported no lstart for pid $P"
fi

# A registry entry for a live process that is not Claude Code must not be counted,
# however plausible the rest of the record looks.
E=$(new_env notclaude)
SELF_START=$(ps -o lstart= -p $$ | sed -E 's/^ +//; s/ +$//')
mkreg "$E" "$$" "bbbbbbbb-0000-4000-8000-000000000000" "not-claude" "busy" "$SELF_START"
sx "$E" status --json >"$E/status.json" 2>/dev/null
chk "a live non-claude process is not counted" "$(jget claimants <"$E/status.json")" "0"

# When `ps` can say nothing about any recorded pid, entries are treated as alive. That
# over-counts claimants, which under-allocates. The opposite default would hand out
# window share that is already spoken for.
E=$(new_env failsafe)
DEAD=$(dead_pids 4 | tr '\n' ' ')
chk "four non-existent pids were found for the fixture" "$(echo $DEAD | wc -w | tr -d ' ')" "4"
i=0
for p in $DEAD; do
  i=$((i + 1))
  mkreg "$E" "$p" "$(printf 'cccccccc-%04d-4000-8000-000000000000' "$i")" \
    "failsafe-$i" "idle" "Mon Jan  5 01:02:03 2026"
done
sx "$E" status --json >"$E/status.json" 2>/dev/null
chk "an unprobeable registry fails safe to all-alive" "$(jget claimants <"$E/status.json")" "4"

# ---------------------------------------------------------------------------
section "Accounts: only sessions on the same account share a window"
# ---------------------------------------------------------------------------

# Own fixture variables (EA, EN): the next section reuses $E from the one before.

# A stub like spawn_stub, started with exactly the environment given, so its
# /proc/<pid>/environ says which credential it was "started" with.
spawn_stub_env() {
  local root="$1" n="$2"; shift 2
  local path="$root/bin/claude-eval-stub-$n"
  ln -sf /bin/sleep "$path"
  env -i "$@" "$path" 120 >/dev/null 2>&1 &
  STUB_PID=$!
  STUB_PIDS="$STUB_PIDS $STUB_PID"
  disown "$STUB_PID" 2>/dev/null || true
}

if [ -r /proc/self/environ ]; then
  EA=$(new_env accounts)
  printf '{"oauthAccount":{"accountUuid":"u-1","organizationUuid":"o-1","emailAddress":"login@example.com"}}' \
    >"$EA/home/.claude.json"
  SA="dddddddd-0000-4000-8000-00000000000a"
  SB="dddddddd-0000-4000-8000-00000000000b"
  SC="dddddddd-0000-4000-8000-00000000000c"
  spawn_stub_env "$EA" a HOME="$EA/home" ANTHROPIC_API_KEY=eval-secret-a; PA="$STUB_PID"
  spawn_stub_env "$EA" b HOME="$EA/home" ANTHROPIC_API_KEY=eval-secret-b; PB="$STUB_PID"
  spawn_stub_env "$EA" c HOME="$EA/home";                                PC="$STUB_PID"
  sleep 0.4
  for pair in "$PA:$SA:acct-a" "$PB:$SB:acct-b" "$PC:$SC:acct-c"; do
    p=${pair%%:*}; rest=${pair#*:}; sid=${rest%%:*}; nm=${rest#*:}
    mkreg "$EA" "$p" "$sid" "$nm" "busy" "$(ps -o lstart= -p "$p" | sed -E 's/^ +//; s/ +$//')"
  done
  mkpayload "$SA" "seven_day:20:$((NOW + 86400))" | sx "$EA" record >/dev/null
  mkpayload "$SB" "seven_day:80:$((NOW + 86400))" | sx "$EA" record >/dev/null

  sx "$EA" plan --session "$SA" >"$EA/plan.json" 2>/dev/null
  chk "a session splits only with its own account" "$(jget claimants <"$EA/plan.json")" "1"
  chk "and plans against its own account's reading" "$(jget grant_mpp <"$EA/plan.json")" "70000"
  sx "$EA" plan --session "$SB" >"$EA/plan.json" 2>/dev/null
  chk "the other account sees its own window" "$(jget grant_mpp <"$EA/plan.json")" "10000"

  sx "$EA" status --json >"$EA/status.json" 2>/dev/null
  chk "a login with no env credential is labelled by its email" \
    "$(python3 -c '
import json,sys
d=json.load(sys.stdin)
print([s.get("account") for s in d["sessions"] if s["session_id"].endswith("c")][0])' <"$EA/status.json")" \
    "login@example.com"
  if grep -rq "eval-secret" "$EA/state" "$EA/status.json"; then
    bad "no credential is written or printed" "found eval-secret in state or status output"
  else ok "no credential is written or printed"; fi

  # Accounts are remembered, so a reading keeps its account after its session exits.
  kill "$PA" 2>/dev/null; sleep 0.2
  sx "$EA" plan --session "$SB" >"$EA/plan.json" 2>/dev/null
  chk "a departed session's reading stays with its account" "$(jget grant_mpp <"$EA/plan.json")" "10000"
else
  ok "accounts: skipped, no /proc on this platform (no account is reported there)"
fi

# Nothing known about accounts means no account field at all — not an "unknown" one.
EN=$(new_env noaccount)
mkpayload "$SID" "five_hour:41.2:$((NOW + 14400))" | sx "$EN" record >/dev/null 2>&1
sx "$EN" status --json >"$EN/status.json" 2>/dev/null
chk "with no account known, status carries no account data" \
  "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["accounts"], any("account" in s for s in d["sessions"]))' <"$EN/status.json")" \
  "[] False"
if sx "$EN" status | grep -q ACCOUNT; then bad "no ACCOUNT column without accounts"
else ok "no ACCOUNT column without accounts"; fi

# ---------------------------------------------------------------------------
section "Property 1: the split cannot oversubscribe"
# ---------------------------------------------------------------------------

# Four claimants against a 41.2%-used window: budget is 90000 - 41200 = 48800 mpp. The
# proof says the grants sum to no more than that; this checks the compiled binary agrees.
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" >"$E/state/samples.ndjson"

total=0
for i in 1 2 3 4; do
  sid=$(printf 'cccccccc-%04d-4000-8000-000000000000' "$i")
  g=$(sx "$E" plan --session "$sid" 2>/dev/null | jget grant_mpp)
  total=$((total + g))
done
chk_le "sum of four grants does not exceed the budget" "$total" "48800"

# And a session the registry has never heard of is added as an extra claimant rather
# than handed a share the split was not computed against.
g_unknown=$(sx "$E" plan --session "dddddddd-0000-4000-8000-000000000000" 2>/dev/null \
  | jget grant_mpp)
chk "an unknown session counts itself in" \
  "$(sx "$E" plan --session "dddddddd-0000-4000-8000-000000000000" 2>/dev/null | jget claimants)" "5"
chk_le "and its grant fits the five-way split" "$g_unknown" "$((48800 / 5))"

# ---------------------------------------------------------------------------
section "Property 2: niceness is monotone and clamped"
# ---------------------------------------------------------------------------

grant_at() { sx "$E" plan --session "$1" --nice "$2" 2>/dev/null | jget grant_mpp; }

ME="cccccccc-0001-4000-8000-000000000000"
g_lo=$(grant_at "$ME" -20)
g_mid=$(grant_at "$ME" 0)
g_hi=$(grant_at "$ME" 19)
if [ "$g_lo" -gt "$g_mid" ] && [ "$g_mid" -gt "$g_hi" ]; then
  ok "grant decreases strictly as niceness rises ($g_lo > $g_mid > $g_hi)"
else
  bad "nice monotonicity" "nice -20/0/19 gave $g_lo / $g_mid / $g_hi"
fi
chk "a yielding session is not starved (nice 19 still gets a grant)" \
  "$([ "$g_hi" -gt 0 ] && echo yes || echo no)" "yes"
chk "niceness above the range clamps to 19"  "$(grant_at "$ME" 999)"  "$g_hi"
chk "niceness below the range clamps to -20" "$(grant_at "$ME" -999)" "$g_lo"

# ---------------------------------------------------------------------------
section "Property 4b: the sprint sequence stays inside the grant"
# ---------------------------------------------------------------------------

# Property 1 bounds a single instant. Without this, the split could be sound while the
# sequence of sprints it licenses still overspent the window.
for nice in -20 -10 0 10 19; do
  read -r grant budget sprints <<<"$(sx "$E" plan --session "$ME" --nice "$nice" 2>/dev/null \
    | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(p["grant_mpp"], p["sprint_budget_mpp"], p["sprints_remaining"])')"
  chk_le "nice $nice: sprints x sprint_budget <= grant" "$((sprints * budget))" "$grant"
done

# ---------------------------------------------------------------------------
section "Property 4: sleep and cron stay inside the guard rails"
# ---------------------------------------------------------------------------

# Sweep the whole reachable input space: exhausted, nearly exhausted, fresh, and a
# rolled-over window, each at both ends of the nice range.
for used in 0 41200 89900 95000; do
  for resets in 60 3600 400000; do
    E2=$(new_env "sleep-$used-$resets")
    printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":%d,"r5":%d}\n' \
      "$NOW" "$SID" "$used" "$((NOW + resets))" >"$E2/state/samples.ndjson"
    for nice in -20 19; do
      s=$(sx "$E2" plan --session "$SID" --nice "$nice" 2>/dev/null | jget sleep_seconds)
      if [ "$s" -lt 60 ] || [ "$s" -gt 3600 ]; then
        bad "sleep bounds (used=$used resets=+$resets nice=$nice)" "got $s"
      fi
    done
  done
done
ok "sleep_seconds stayed in [60,3600] across 24 input combinations"

# A cron expression the agent is told to hand to CronCreate must be a 5-field one.
fields=$(sx "$E" plan --session "$ME" 2>/dev/null | jget cron | awk '{print NF}')
chk "cron is a 5-field expression" "$fields" "5"

# The minute offset is derived from the session id, so concurrent sessions spread across
# the hour deterministically instead of all landing on the same minute.
c1=$(sx "$E" plan --session "$ME" 2>/dev/null | jget cron)
c2=$(sx "$E" plan --session "$ME" 2>/dev/null | jget cron)
chk "cron is stable for a given session" "$c1" "$c2"

# ---------------------------------------------------------------------------
section "Property 5: the ledger resolves independently of arrival order"
# ---------------------------------------------------------------------------

# Two sessions append at the same instant and each sees a different prefix of the log.
# The resolved priority must not depend on which order the records landed in.
mk_ledger() { # mk_ledger <root> <order>
  local root="$1"
  if [ "$2" = "forward" ]; then
    printf '{"t":1000,"s":"%s","n":-5,"src":"user"}\n{"t":2000,"s":"%s","n":10,"src":"inferred"}\n' \
      "$ME" "$ME" >"$root/state/ledger.ndjson"
  else
    printf '{"t":2000,"s":"%s","n":10,"src":"inferred"}\n{"t":1000,"s":"%s","n":-5,"src":"user"}\n' \
      "$ME" "$ME" >"$root/state/ledger.ndjson"
  fi
}

EA=$(new_env order-a); EB=$(new_env order-b)
for root in "$EA" "$EB"; do
  printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
    "$NOW" "$SID" "$((NOW + 14400))" >"$root/state/samples.ndjson"
done
mk_ledger "$EA" forward
mk_ledger "$EB" reverse
wa=$(sx "$EA" plan --session "$ME" 2>/dev/null | jget weight)
wb=$(sx "$EB" plan --session "$ME" 2>/dev/null | jget weight)
chk "resolved weight is the same in both arrival orders" "$wa" "$wb"
# nice -5 is weight 1414 in the table; nice 10 would be 500. The user record must win
# over the later inferred one, so an agent cannot promote itself past its operator
# simply by declaring afterwards.
chk "the user declaration wins over a later inferred one" "$wa" "1414"

# A duplicated delivery is absorbed by the join rather than double-counted.
EC=$(new_env order-dup)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" >"$EC/state/samples.ndjson"
printf '{"t":1000,"s":"%s","n":-5,"src":"user"}\n{"t":1000,"s":"%s","n":-5,"src":"user"}\n' \
  "$ME" "$ME" >"$EC/state/ledger.ndjson"
chk "a duplicated declaration changes nothing" \
  "$(sx "$EC" plan --session "$ME" 2>/dev/null | jget weight)" "$wa"

# ---------------------------------------------------------------------------
section "Operator precedence: --user outranks a later --nice"
# ---------------------------------------------------------------------------

E=$(new_env precedence)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" >"$E/state/samples.ndjson"

sx "$E" claim --session "$ME" --nice -10 --user >/dev/null 2>&1
chk "a recorded user claim is honoured" \
  "$(sx "$E" plan --session "$ME" 2>/dev/null | jget weight)" "2000"
chk "and a conflicting --nice on the invocation does not override it" \
  "$(sx "$E" plan --session "$ME" --nice 19 2>/dev/null | jget weight)" "2000"

# An agent's own inferred claim, by contrast, is advisory and a later one replaces it.
E=$(new_env inferred)
printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
  "$NOW" "$SID" "$((NOW + 14400))" >"$E/state/samples.ndjson"
sx "$E" claim --session "$ME" --nice 10 >/dev/null 2>&1
chk "an inferred claim is honoured when nothing outranks it" \
  "$(sx "$E" plan --session "$ME" 2>/dev/null | jget weight)" "500"

# ---------------------------------------------------------------------------
section "Housekeeping"
# ---------------------------------------------------------------------------

E=$(new_env gc)
{
  printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
    "$((NOW - 30 * 86400))" "$SID" "$((NOW + 14400))"
  printf '{"t":%d,"s":"%s","m":"claude-opus-5","u5":41200,"r5":%d}\n' \
    "$NOW" "$SID" "$((NOW + 14400))"
} >"$E/state/samples.ndjson"
printf '{"t":%d,"s":"%s","n":-5,"src":"user"}\n{"t":%d,"s":"%s","n":-5,"src":"user"}\n' \
  "$((NOW - 30 * 86400))" "$ME" "$NOW" "$ME" >"$E/state/ledger.ndjson"

sx "$E" gc --days 8 >"$E/gc.txt" 2>&1
chk "gc keeps only the in-horizon sample" \
  "$(wc -l <"$E/state/samples.ndjson" | tr -d ' ')" "1"
chk "gc keeps only the in-horizon ledger record" \
  "$(wc -l <"$E/state/ledger.ndjson" | tr -d ' ')" "1"
chk "gc left the recent sample intact" \
  "$(jget t <"$E/state/samples.ndjson")" "$NOW"

# ---------------------------------------------------------------------------
section "Exit codes and blast radius"
# ---------------------------------------------------------------------------

E=$(new_env exits)
sx "$E" plan >/dev/null 2>&1
chk "plan without a session id exits 2" "$?" "2"
sx "$E" claim --session "$ME" >/dev/null 2>&1
chk "claim without --nice exits 2" "$?" "2"
sx "$E" help >/dev/null 2>&1
chk "help exits 0" "$?" "0"

# Nothing may be written outside STRATIFY_HOME. The Claude Code directories are opened
# read-only and this is the check that says so.
E=$(new_env blastradius)
mkpayload "$SID" "five_hour:41.2:$((NOW + 14400))" | sx "$E" record >/dev/null 2>&1
sx "$E" status --json >/dev/null 2>&1
sx "$E" plan --session "$SID" >/dev/null 2>&1
sx "$E" claim --session "$SID" --nice 5 >/dev/null 2>&1
sx "$E" gc >/dev/null 2>&1
stray=$(find "$E/home" -type f 2>/dev/null | wc -l | tr -d ' ')
chk "no command wrote anything under \$HOME" "$stray" "0"
written=$(cd "$E/state" && find . -type f | sort | tr '\n' ' ')
chk "only the two log files were written" "$written" "./ledger.ndjson ./samples.ndjson "

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%s%s%s\n' "$B" "----------------------------------------------------------------" "$Z"
if [ "$N_FAIL" -eq 0 ]; then
  printf '%s%d checks passed%s, 0 failed.\n' "$G" "$N_PASS" "$Z"
  printf '%sThis is evidence, not a verdict: whether it is sufficient is the operator'"'"'s call.%s\n' \
    "$D" "$Z"
  exit 0
else
  printf '%d passed, %s%d failed%s:\n' "$N_PASS" "$R" "$N_FAIL" "$Z"
  printf '%s' "$FAILURES"
  exit 1
fi
