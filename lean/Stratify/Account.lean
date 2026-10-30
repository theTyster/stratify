import Lean.Data.Json
import Stratify.Types
import Stratify.Json
import Stratify.Ndjson
import Stratify.Paths
import Stratify.Sha256

/-!
# Which account a session spends against

Several accounts can run on one machine at once — a subscription in one shell, an API
key or a gateway in another — and only sessions on the same account share a window.
Nothing Claude Code records says which account a session is on: the statusline payload
has no account field, the session registry has none, and the `userEmail` in transcripts
is copied from the config directory's login, which describes whoever last logged in,
not the credential a session is actually running on.

What *is* authoritative is how the session was started. Claude Code takes its
credential from the environment when one is there (`ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, or a cloud-provider switch), and
otherwise from the login in `<CLAUDE_CONFIG_DIR or $HOME>/.claude.json`. The session's
own process still holds that environment even though Claude Code scrubs the tokens from
its children, so it is read from `/proc/<pid>/environ`.

## Known, or nothing

An account is reported only when it was read that way. There is no "unknown" value:
a session whose environment cannot be read — another platform, another user — simply
has no account, and is treated exactly as every session was before accounts existed.
That is deliberate. A guessed account is worse than none, because the allocator acts on
it; and an account column full of "unknown" invites hunting for a signal that does not
exist.

## Credentials never leave this process

A credential is hashed in memory (`Sha256`) and only a prefix of the digest is kept: 16
hex digits for the key, 4 for the label. Neither is stored or printed in any form that
could be reversed to the credential.
-/

namespace Stratify.Account

open Lean

/-! ## The environment -/

/-- Split a `/proc/<pid>/environ` blob into `NAME=value` pairs. Entries that are not
valid UTF-8 are dropped one at a time, so one odd variable cannot hide the rest. -/
def parseEnviron (b : ByteArray) : List (String × String) := Id.run do
  let mut out : Array (String × String) := #[]
  let mut start := 0
  for i in [0:b.size + 1] do
    if i == b.size || b.get! i == 0 then
      if i > start then
        if let some s := String.fromUTF8? (b.extract start i) then
          match s.splitOn "=" with
          | k :: rest => out := out.push (k, "=".intercalate rest)
          | [] => pure ()
      start := i + 1
  return out.toList

/-- Value of a variable, treating an empty value as unset. -/
def getVar (env : List (String × String)) (k : String) : Option String :=
  (env.find? (·.1 == k)).bind fun (_, v) => if v == "" then none else some v

/-- Credential variables, with the words a person would use for them. -/
def credVars : List (String × String) :=
  [("ANTHROPIC_API_KEY", "api key"), ("ANTHROPIC_AUTH_TOKEN", "auth token"),
   ("CLAUDE_CODE_OAUTH_TOKEN", "oauth token")]

/-- Cloud-provider switches. These sessions bill to the provider, never to a
subscription window. -/
def providerVars : List (String × String) :=
  [("CLAUDE_CODE_USE_BEDROCK", "bedrock"), ("CLAUDE_CODE_USE_VERTEX", "vertex"),
   ("CLAUDE_CODE_USE_FOUNDRY", "foundry")]

private def truthy (v : String) : Bool := v != "0" && v.toLower != "false"

/-- `https://llm.example.com/v1` → `llm.example.com`. -/
def hostOf (url : String) : String :=
  let rest := match url.splitOn "://" with
    | [_, r] => r
    | _ => url
  (rest.splitOn "/").headD rest

/-! ## The config directory's login -/

/-- The `oauthAccount` block of a `.claude.json`. -/
structure Login where
  account : String
  org : String
  email : String
  deriving Repr, Inhabited

def parseLogin (txt : String) : Option Login := do
  let j ← J.parseLine txt
  let a ← J.str? j ["oauthAccount", "accountUuid"]
  if a == "" then none
  pure { account := a, org := J.str j ["oauthAccount", "organizationUuid"]
         email := J.str j ["oauthAccount", "emailAddress"] }

/-- The key for a logged-in account. Shared with Cowork, whose store is laid out by the
same two ids, so a CLI session and a Cowork session on one account group together. -/
def loginKey (account org : String) : String := s!"acct:{account}/{org}"

private def take (n : Nat) (s : String) : String := String.ofList (s.toList.take n)

/-! ## Resolution -/

/-- The account a session with this environment and this config-directory login spends
against. Pure, so the precedence is checkable below.

Precedence follows Claude Code's: a cloud-provider switch, then any credential in the
environment, then the login. When several credential variables are set they are hashed
together, so two sessions with the same set always agree, whichever one Claude Code
ends up preferring. -/
def resolve (env : List (String × String)) (login : Option Login) : Option Account :=
  let base := getVar env "ANTHROPIC_BASE_URL"
  let at_ := match base with
    | some u => s!" @ {hostOf u}"
    | none => ""
  match providerVars.find? (fun (v, _) => (getVar env v).any truthy) with
  | some (_, name) => some { key := s!"cloud:{name}", label := name }
  | none =>
    let creds := credVars.filterMap fun (v, word) => (getVar env v).map (v, word, ·)
    if !creds.isEmpty then
      let material := "\n".intercalate (creds.map fun (v, _, val) => s!"{v}={val}")
        ++ s!"\nANTHROPIC_BASE_URL={base.getD ""}"
      let digest := Sha256.hex material.toUTF8
      let words := " + ".intercalate (creds.map fun (_, w, _) => w)
      some { key := s!"cred:{take 16 digest}", label := s!"{words} ·{take 4 digest}{at_}" }
    else
      login.map fun l =>
        { key := loginKey l.account l.org
          label := (if l.email != "" then l.email else s!"account ·{take 8 l.account}") ++ at_ }

/-- `.claude.json` for a session: Claude Code reads
`join(CLAUDE_CONFIG_DIR || homedir(), ".claude.json")`, with the session's own `HOME`. -/
def configFileFor (env : List (String × String)) : IO System.FilePath := do
  match getVar env "CLAUDE_CONFIG_DIR" with
  | some d => return System.FilePath.mk d / ".claude.json"
  | none =>
    match getVar env "HOME" with
    | some h => return System.FilePath.mk h / ".claude.json"
    | none => return (← Paths.home) / ".claude.json"

def readLogin (path : System.FilePath) : IO (Option Login) := do
  try return parseLogin (← IO.FS.readFile path) catch _ => return none

/-- The account of a live CLI session, read from its own process. `none` whenever the
environment cannot be read: the login is only consulted once the environment has been
seen to carry no credential, because otherwise it may describe a different account. -/
def ofPid (pid : Nat) : IO (Option Account) := do
  if pid == 0 then return none
  let bytes ← try IO.FS.readBinFile (Paths.procEnviron pid) catch _ => return none
  let env := parseEnviron bytes
  if env.isEmpty then return none
  return resolve env (← readLogin (← configFileFor env))

/-! ## Remembering accounts

Readings outlive the sessions that took them, and a reading is only attributable while
its session's account is known. So the account of every session seen is appended to
`accounts.ndjson`, keyed by session id. Later lines win. -/

def encodeEntry (ts : Epoch) (sid : String) (a : Account) : String :=
  (Json.mkObj [("t", Json.num (JsonNumber.fromNat ts)), ("s", Json.str sid),
               ("k", Json.str a.key), ("l", Json.str a.label)]).compress

def decodeEntry (line : String) : Option (Epoch × String × Account) := do
  let j ← J.parseLine line
  let sid ← J.str? j ["s"]
  let k ← J.str? j ["k"]
  pure (J.nat j ["t"], sid, { key := k, label := J.str j ["l"] })

/-- Session id to account, last entry winning. -/
def loadMap : IO (Std.HashMap String Account) := do
  let mut m : Std.HashMap String Account := {}
  for line in ← Ndjson.readAll (← Paths.accountsFile) do
    if let some (_, sid, a) := decodeEntry line then
      m := m.insert sid a
  return m

/-- Append the sessions whose account is new or has changed. Best effort: losing this
write only means a future reading goes unattributed, which is how readings were treated
before accounts existed. -/
def remember (now : Epoch) (known : Std.HashMap String Account)
    (seen : Array (String × Account)) : IO Unit := do
  try
    let path ← Paths.accountsFile
    for (sid, a) in seen do
      if known.get? sid != some a then
        Ndjson.append path (encodeEntry now sid a)
  catch _ => pure ()

/-! ## Independence declarations

An operator's statement that an account draws on a window no other account shares — an
API key billed per token, a gateway with its own quota. Nothing on the machine can
verify that, which is why it is a declaration and why `Pool` otherwise refuses to
separate accounts without measured proof. Stored in the same file, last line per key
winning. -/

def encodeIndependence (ts : Epoch) (key : String) (independent : Bool) : String :=
  (Json.mkObj [("t", Json.num (JsonNumber.fromNat ts)), ("k", Json.str key),
               ("ind", Json.bool independent)]).compress

/-- Keys currently declared independent. -/
def loadIndependent : IO (List String) := do
  let mut m : Std.HashMap String Bool := {}
  for line in ← Ndjson.readAll (← Paths.accountsFile) do
    if let some j := J.parseLine line then
      if let (some k, some b) := (J.str? j ["k"], (J.path? j ["ind"]).bind (·.getBool?.toOption)) then
        m := m.insert k b
  return m.toList.filterMap fun (k, b) => if b then some k else none

def declareIndependence (ts : Epoch) (key : String) (independent : Bool) : IO Unit := do
  Ndjson.append (← Paths.accountsFile) (encodeIndependence ts key independent)

/-! ## Checks -/

private def aLogin : Login := { account := "u-1", org := "o-1", email := "me@example.com" }

-- A NUL-separated blob, including an empty trailing entry and a value containing `=`.
#guard parseEnviron "A=1\x00B=x=y\x00\x00".toUTF8 == [("A", "1"), ("B", "x=y")]

-- No credential: the login decides.
#guard (resolve [("HOME", "/h")] (some aLogin)).map (·.key) == some "acct:u-1/o-1"
#guard (resolve [("HOME", "/h")] (some aLogin)).map (·.label) == some "me@example.com"

-- A credential outranks the login, which may describe someone else entirely.
#guard ((resolve [("CLAUDE_CODE_OAUTH_TOKEN", "t1")] (some aLogin)).map
    (·.key.startsWith "cred:")) == some true

-- Same credential, same key; different credential or endpoint, different key.
#guard (resolve [("ANTHROPIC_API_KEY", "k")] none) == (resolve [("ANTHROPIC_API_KEY", "k")] none)
#guard (resolve [("ANTHROPIC_API_KEY", "k")] none) != (resolve [("ANTHROPIC_API_KEY", "j")] none)
#guard (resolve [("ANTHROPIC_API_KEY", "k")] none)
    != (resolve [("ANTHROPIC_API_KEY", "k"), ("ANTHROPIC_BASE_URL", "https://gw")] none)

-- The credential appears nowhere in what is kept.
#guard ((resolve [("ANTHROPIC_API_KEY", "sk-secret-value")] none).map fun a =>
    (a.key.splitOn "sk-secret").length == 1 && (a.label.splitOn "sk-secret").length == 1)
  == some true

-- A gateway is named in the label.
#guard ((resolve [("ANTHROPIC_AUTH_TOKEN", "k"), ("ANTHROPIC_BASE_URL", "https://llm.example.com/v1")]
    none).map (·.label.endsWith " @ llm.example.com")) == some true

-- A provider switch wins, and `0`/empty do not count as switched on.
#guard (resolve [("CLAUDE_CODE_USE_BEDROCK", "1"), ("ANTHROPIC_API_KEY", "k")] none).map (·.key)
  == some "cloud:bedrock"
#guard ((resolve [("CLAUDE_CODE_USE_BEDROCK", "0"), ("ANTHROPIC_API_KEY", "k")] none).map
    (·.key.startsWith "cred:")) == some true

-- Nothing readable: no account, not an "unknown" one.
#guard (resolve [("HOME", "/h")] none).isNone

-- An empty credential is no credential.
#guard (resolve [("ANTHROPIC_API_KEY", "")] (some aLogin)).map (·.key) == some "acct:u-1/o-1"

#guard (parseLogin "{\"oauthAccount\":{\"accountUuid\":\"a\",\"organizationUuid\":\"o\",\"emailAddress\":\"e\"}}").map
    (·.account) == some "a"
#guard (parseLogin "{\"oauthAccount\":{}}").isNone

#guard (decodeEntry (encodeEntry 5 "s1" { key := "k", label := "l" })).map (·.2.2.key) == some "k"

end Stratify.Account
