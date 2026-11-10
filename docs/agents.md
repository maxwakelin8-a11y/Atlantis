# Bots (PRD §7b, M5)

A bot is a markdown file in the LifeOS vault: `machine/atlantis/agents/<id>.md`. The file name
(lowercase letters, digits, dashes) is its id. Atlantis writes the default bots (`school.md`,
`coach.md`, `builder.md`) when it first needs the bots, each only if it doesn't exist, and never
overwrites them. Coach (planning, triggers chat + task) and Builder (writing, chat + mention) are
suggest-only by default. A School file written by M5 has `triggers: [chat]`: add `task` and
`mention` to use it from Tasks and Docs.

```markdown
---
name: School
avatar: 🎓
model: sonnet            # haiku, sonnet, opus, fable, or a claude-… id
autonomy: suggest        # suggest (Inbox only) · ask · act (allow-listed actions run)
triggers: [chat, task, mention]  # schedule HH:MM and event <name> come in M7
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
