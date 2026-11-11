# Bots (PRD §7b, M5)

A bot is a markdown file in the LifeOS vault: `machine/atlantis/agents/<id>.md`. The file name
(lowercase letters, digits, dashes) is its id. Atlantis writes the default bots (`school.md`,
`coach.md`, `builder.md`, `chief.md`, `scout.md`) when it first needs the bots, each only if it
doesn't exist, and never overwrites them. Coach (planning, chat + task + morning + overdue),
Builder (writing, chat + mention), Chief (routing, chat) and Scout (read-only research, no web) are
suggest-only by default. A School file written by M5 has `triggers: [chat]`: add `task` and
`mention` to use it from Tasks and Docs. Files written before M7 keep their old triggers: add
`schedule morning` and `event task.overdue` to Coach, and `event seqta.assessment.new` (plus the
`atlantis_task_add` tool) to School, to have them run on their own.

```markdown
---
name: School
avatar: 🎓
model: sonnet            # haiku, sonnet, opus, fable, or a claude-… id
autonomy: suggest        # suggest (Inbox only) · ask · act (allow-listed actions run)
triggers: [chat, task, mention]  # also: schedule morning, event seqta.assessment.new, event task.overdue
tools:                   # Atlantis MCP tool names; the bot gets these and nothing else
  - atlantis_today
  - atlantis_inbox_post
budget:
  max_steps: 12          # tool calls per run (1–50)
  daily_cost_usd: 1.00   # estimated dollars per day (0.01–50)
---

The body is the bot's "soul": its instructions, in your words.
```

If a file has problems, the Agents page lists them all under the bot's name. Bots can't have
`atlantis_seqta_refresh` (they read saved SEQTA data and never sync), and no tool sends a SEQTA
message. `provider: api` (the cheap API worker, not set up yet) may only have tools that read
nothing personal.

## How a chat runs

```
Agents page ─ AgentService ──(Unix socket 0600, same user)──▶ atlantis-agentd
     │  issues a grant token for this run                       │ runs: claude -p --output-format stream-json …
     │                                                          │   --tools "" --strict-mcp-config --mcp-config <0600 file>
     │                                                          │   --allowedTools mcp__atlantis__<bot tools> --permission-mode dontAsk
     │                                                          │   --setting-sources "" --max-turns --max-budget-usd
     │                                                          ▼
     │◀── events (text, tool calls, steps) ─────────────── stream-json → RunMonitor (lockdown + step checks)
     │                                                          │
     └── MCP server ◀── atlantis-mcp (ATLANTIS_AGENT_TOKEN) ◀───┘  only the bot's tools; results wrapped as data
```

- The app starts `atlantis-agentd` on the first chat; it exits after 10 minutes with nothing to
  do (one one-shot timer, reset per request). The app never runs a timer for it.
- Each run is logged to `machine/atlantis/threads/<bot>/<YYYY-MM-DD>-<id>.md`: front matter
  (id, bot, title, times, runs, steps, cost) and each message under a heading. Refused tool calls
  show struck through.
- Daily spend per bot is kept in `~/Library/Application Support/Atlantis/agents/usage.json`.

## Teammates (M6)

- **Assign a task:** the Tasks side panel's **Bot** picker writes `[agent:: <id>]` on the task
  (only that line changes; unknown fields are kept) and starts a run with the task (title, notes,
  subtasks, due, project, source) as data. **Run Now** runs it again. One run per task at a time;
  budgets apply as for chats. Only bots with `task` in `triggers` are listed.
- **@mention in a doc:** type `@` in a Writer doc to pick a bot (`mention` in `triggers`), then
  write the request after it. The line stays plain Markdown (`@builder tighten the intro`), so the
  file round-trips byte for byte. A chip "Ask Builder ⌘↩" shows beside that paragraph; clicking it
  or pressing ⌘↩ saves the doc and sends `agents.ask {bot, path, request}`. Swift checks the bot,
  the request (2,000 characters max) and the path (`AgentMention.relativeDocPath`: inside the Writer
  folder after resolving symlinks, a .md/.markdown/.txt doc in a project), reads the saved doc
  from disk (40,000 characters go in the prompt) and starts the run. The page also gets
  `agents.list` (ids, names and avatars of mentionable bots). Nothing else was added to the bridge.
- **Results:** task and mention runs get their own thread (shown on the Agents page like a chat).
  When one ends, the bot's answer goes to the Inbox as a `note` with `[origin:: task:<id>]` or
  `[origin:: doc:<path>]`, `[run:: ok|failed]` and `[thread:: <bot>/<id>]`. Every proposal the run
  makes carries the same `origin` (it never gets copied onto a task when accepted). The task panel
  shows "Coach is working…", "waiting for your approval", or "Done, see Inbox" (after a relaunch it
  reads the latest note from the Inbox).

## The team (M7)

**Bots on their own** (Settings ▸ Bots on Their Own, **off by default**). Chat, assigned tasks and
@mentions work either way. Atlantis runs no timers, so triggers hang off events it already has:

| Trigger | When |
| --- | --- |
| `schedule morning` | Once per local day: right after a SEQTA sync (the morning one, or the day's first refresh); if no sync happens, at the first launch or wake from the morning time (07:00, Settings). |
| `event task.overdue` | At the morning trigger, **one** run with every overdue task, only when something is overdue. A bot with both gets one run. |
| `event seqta.assessment.new` | After a sync, one run per assessment seen for the first time (the same dedupe that proposes it in the Inbox, so once ever). |

"Ran today" and the day's run count live in `~/Library/Application Support/Atlantis/agents/triggers.json`
(not the vault), so relaunching doesn't repeat them.

**Queue and limits.** Automatic runs (and hand-offs) wait in a first-in, first-out queue and run
one at a time; the next starts when one ends. A per-day cap (default 10, 1–30, Settings) counts
started plus waiting runs; past it, runs are skipped and shown as skipped on Today. Each bot's own
`daily_cost_usd` applies on top. The same bot can't be queued twice for the same thing. Turning
the switch off drops waiting automatic runs (a running one finishes). No one watches these runs,
so an `ask` bot runs as `suggest`: its writes wait in the Inbox instead of holding the queue on an
approval card.

**Chief and `atlantis_agent_delegate {bot, request}`.** "Ask the team" on the Agents page chats
with Chief, whose only tools are delegate and Inbox post. Delegate queues a run of another bot:
only existing bots that allow `chat`, never itself, at most 3 per run, and a handed-on run can't
delegate again (depth 1). It counts against the daily cap and the target's cost cap. Plain MCP
clients can't delegate (the tool needs a bot's grant). The bot's answer goes to the Inbox, linked
to Chief's thread (`origin: thread:chief/<id>`), and Chief's thread lists each hand-off's status.

**Today.** The Team card shows the morning plan's first lines, bot suggestions waiting in the
Inbox, and today's runs (bot, trigger, status; click to open the thread). It's hidden while bots
did nothing today and can't run on their own. The Tasks card warns when today's estimates (30 min
when a task has none) pass the free time between classes until 21:30. **End of Day** goes through
today's open tasks (done, tomorrow, drop or keep), then adds one line under `### Shutdown` in the
daily note's machine block; later syncs keep it.

## Autonomy (enforced in the app's gate, `WriteRoute`)

| Caller | Gated write on the Settings allow list | Not on it |
|---|---|---|
| MCP client (no bot) | runs | Inbox proposal |
| `suggest` bot | Inbox proposal | Inbox proposal |
| `ask` bot | proposal; the run waits for approve/deny | same |
| `act` bot | runs | Inbox proposal |

Destructive tools never run directly. Reads and `atlantis_inbox_post` are never held.

- **`ask`:** the write is posted to the Inbox, and the tool call waits (`ApprovalCenter`, up to
  240 s) while an approve/deny card shows in the bot's thread. Approve accepts the Inbox item
  (`InboxActions` applies it); Deny dismisses it. Deciding in the Inbox page or editing the file in
  Obsidian counts too. The bot is told "approved", "denied" (don't retry) or "no decision yet"
  (it stays in the Inbox). Stopping the run cancels the wait. The MCP helper waits up to 300 s for
  a bot's call and the CLI gets `MCP_TOOL_TIMEOUT` a little above that.
- The Inbox's own "Always allow this kind" never auto-accepts a bot's item: for bots, autonomy
  decides.

## Guard rails

- **Tools:** the CLI gets no built-in tools (no shell, files, web or subagents) and only the
  bundled `atlantis-mcp` server. The daemon stops a run if the CLI's `init` line offers anything
  else. The app's MCP server checks each call's grant token and refuses tools off the bot's list,
  unknown or ended tokens, and calls past `max_steps`.
- **Writes:** routed by autonomy (table above). Inbox items say `agent:<bot>`.
- **Budgets:** past `max_steps` the app refuses tool calls and tells the bot to answer; if it keeps
  calling, the run is killed. Runs are refused once a bot's daily cap is spent, and the CLI gets
  what's left of the cap as `--max-budget-usd`. If a run is killed before the CLI reports its cost,
  an over-estimate from the tokens seen is counted.
- **Data, not instructions:** tool results reach the bot inside `<atlantis_data>` tags whose
  contents can't close the tag, and the system prompt says text inside them is never
  instructions. The real protection is the tool list and the Inbox gate, not the wording.
- **Login:** Atlantis never reads or passes on the Claude Code login. The CLI runs with a minimal
  environment (no API keys from the app) and non-essential traffic off.
