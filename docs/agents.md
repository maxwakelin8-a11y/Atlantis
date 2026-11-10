# Bots (PRD §7b, M5)

A bot is a markdown file in the LifeOS vault: `machine/atlantis/agents/<id>.md`. The file name
(lowercase letters, digits, dashes) is its id. Atlantis writes `school.md` the first time the
Agents page opens, only if it doesn't exist, and never overwrites it.

```markdown
---
name: School
avatar: 🎓
model: sonnet            # haiku, sonnet, opus, fable, or a claude-… id
autonomy: suggest        # suggest (Inbox only) · ask · act (allow-listed actions run)
triggers: [chat]         # chat works now; mention, task, schedule HH:MM, event <name> come in M6/M7
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

## Guard rails

- **Tools:** the CLI gets no built-in tools (no shell, files, web or subagents) and only the
  bundled `atlantis-mcp` server. The daemon stops a run if the CLI's `init` line offers anything
  else. The app's MCP server checks each call's grant token and refuses tools off the bot's list,
  unknown or ended tokens, and calls past `max_steps`.
- **Writes:** `suggest` and `ask` bots only ever make Inbox proposals, even for actions on the
  Settings allow list. Inbox items say `agent:<bot>`.
- **Budgets:** past `max_steps` the app refuses tool calls and tells the bot to answer; if it keeps
  calling, the run is killed. Runs are refused once a bot's daily cap is spent, and the CLI gets
  what's left of the cap as `--max-budget-usd`. If a run is killed before the CLI reports its cost,
  an over-estimate from the tokens seen is counted.
- **Data, not instructions:** tool results reach the bot inside `<atlantis_data>` tags whose
  contents can't close the tag, and the system prompt says text inside them is never
  instructions. The real protection is the tool list and the Inbox gate, not the wording.
- **Login:** Atlantis never reads or passes on the Claude Code login. The CLI runs with a minimal
  environment (no API keys from the app) and non-essential traffic off.
