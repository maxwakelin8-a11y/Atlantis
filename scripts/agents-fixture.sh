#!/bin/zsh
# Makes a made-up vault and SEQTA cache (via today-fixture.sh) plus bot files and one made-up
# School thread, for trying the Agents page without the real vault. Everything here is invented.
#
#   scripts/agents-fixture.sh [vault-dir] [cache-dir] [writer-dir]
#       (defaults: /tmp/agents-vault /tmp/agents-seqta /tmp/agents-writer)
#   .build/debug/Atlantis -vaultPath /tmp/agents-vault -debugSeqtaCache /tmp/agents-seqta \
#       -writerPath /tmp/agents-writer -debugPage agents
#
# The bots here use the cheapest model (haiku) and small daily caps, so live checks cost little:
#   -debugAgentAsk "What's due this week?"                                       (chat with School)
#   -debugAgentTask "forces report" -debugAgentBot coach -debugAutoApprove YES   (Coach asks first)
#   -debugAgentMention /tmp/agents-writer/Essay/Draft/Intro.md -debugAgentBot builder \
#       -debugAgentRequest "Tighten the first paragraph."
# Pass --no-thread to skip the made-up thread.
set -euo pipefail
cd "$(dirname "$0")/.."

thread=1
if [[ "${1:-}" == "--no-thread" ]]; then thread=0; shift; fi
vault="${1:-/tmp/agents-vault}"
cache="${2:-/tmp/agents-seqta}"
writer="${3:-/tmp/agents-writer}"

scripts/today-fixture.sh "$vault" "$cache" > /dev/null
agents="$vault/machine/atlantis/agents"
mkdir -p "$agents"

cat > "$agents/school.md" <<'EOF'
---
name: School
avatar: 🎓
model: haiku
autonomy: suggest
triggers: [chat, task, mention]
tools:
  - atlantis_today
  - atlantis_tasks_list
  - atlantis_inbox_list
  - atlantis_school_timetable
  - atlantis_school_assessments
  - atlantis_school_subjects
  - atlantis_school_notices
  - atlantis_school_messages
  - atlantis_docs_list
  - atlantis_docs_search
  - atlantis_doc_read
  - atlantis_inbox_post
budget:
  max_steps: 8
  daily_cost_usd: 0.50
---

You are School, a study helper for a Year 9 student in Australia. You know their timetable,
assessments, marks, teacher feedback, notices and messages from SEQTA (saved in Atlantis), plus
their tasks and docs.

- Answer from the real data. Look it up with your tools before answering; if something isn't
  there, say so instead of guessing.
- Be short and concrete: what's due, what matters most, and one next step.
- When something should become a task or a reminder, post it to the Inbox so the user can accept
  it. You can't change anything yourself, and you never send messages.
- Use Australian spelling and plain words.
EOF

cat > "$agents/coach.md" <<'EOF'
---
name: Coach
avatar: 🧭
model: haiku
autonomy: ask
triggers: [chat, task]
tools: [atlantis_today, atlantis_tasks_list, atlantis_task_add, atlantis_task_update, atlantis_inbox_post]
budget:
  max_steps: 6
  daily_cost_usd: 0.25
---

You are Coach. Help plan study and rest around the school week. When a task needs a first step,
add one small task for it (atlantis_task_add). Keep it short.
EOF

cat > "$agents/builder.md" <<'EOF'
---
name: Builder
avatar: 🛠️
model: haiku
autonomy: suggest
triggers: [chat, mention]
tools: [atlantis_docs_list, atlantis_docs_search, atlantis_doc_read, atlantis_doc_write, atlantis_inbox_post]
budget:
  max_steps: 6
  daily_cost_usd: 0.25
---

You are Builder, a writing helper. Give short, specific feedback and keep the writer's voice.
When an edit is clearly wanted, propose the full new text with atlantis_doc_write.
EOF

# A task assigned to Coach (the `agent::` field).
print -r -- "- [ ] Start the forces report [due:: $(date -v+3d +%Y-%m-%d)] [project:: Science] [agent:: coach] ^t-f0ace001" >> "$vault/machine/tasks.md"

# A Writer folder with one essay and an @mention in it.
mkdir -p "$writer/Essay/Draft"
print -r -- '{"title":"Bridge design essay"}' > "$writer/Essay/.writer.json"
cat > "$writer/Essay/Draft/Intro.md" <<'EOF'
---
title: Intro
---

Bridges are everywhere, and most of the time we don't even think about them. In this essay I will
explain how a truss bridge carries a load and why engineers still use them today.

@builder tighten this intro and make the thesis clearer
EOF

if (( thread )); then
  dir="$vault/machine/atlantis/threads/school"
  mkdir -p "$dir"
  today=$(date +%Y-%m-%d)
  off=$(date +%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/')
  at() { print -r -- "${today}T$1:00$off"; }

  cat > "$dir/$today-0a1b2c3d.md" <<EOF
---
id: 0a1b2c3d
bot: school
title: "What's due this week?"
created: $(at 08:05)
updated: $(at 08:07)
runs: 2
steps: 4
cost_usd: 0.0094
---

<!-- atlantis:message role="user" at="$(at 08:05)" meta_lines="0" -->
**You** · 8:05 am

What's due this week?

<!-- atlantis:message role="bot" at="$(at 08:05)" tools="atlantis_school_assessments,atlantis_tasks_list" status="ok" steps="2" cost_usd="0.0051" meta_lines="1" -->
**🎓 School** · 8:05 am · 2 steps · \$0.005

> 📝 Read assessments · ✅ Read your tasks

Two things this week:

- **Bridge design essay** (English) is due **tomorrow**. Your plan task is still open.
- **Forces practical report** (Science) is due in **3 days**.

Next step: finish the essay plan tonight, then draft the report's method on Thursday.

<!-- atlantis:message role="user" at="$(at 08:06)" meta_lines="0" -->
**You** · 8:06 am

Can you remind me to start the report on Thursday?

<!-- atlantis:message role="bot" at="$(at 08:07)" tools="atlantis_school_timetable,atlantis_inbox_post" status="ok" steps="2" cost_usd="0.0043" meta_lines="1" -->
**🎓 School** · 8:07 am · 2 steps · \$0.004

> 📚 Read the timetable · 📮 Posted to the Inbox

Done: I posted **"Start the forces report method"** for Thursday to your Inbox. You have Science period 3 that day, so you can ask Mr Newton anything you're stuck on.
EOF

  cat > "$dir/$today-9f8e7d6c.md" <<EOF
---
id: 9f8e7d6c
bot: school
title: "How are my marks going?"
created: $(at 07:30)
updated: $(at 07:31)
runs: 1
steps: 1
cost_usd: 0.0030
---

<!-- atlantis:message role="user" at="$(at 07:30)" meta_lines="0" -->
**You** · 7:30 am

How are my marks going?

<!-- atlantis:message role="bot" at="$(at 07:31)" tools="atlantis_school_subjects" status="ok" steps="1" cost_usd="0.0030" meta_lines="1" -->
**🎓 School** · 7:31 am · 1 step · \$0.003

> 🎒 Read subjects

Your Visual Art self portrait has marks released. The other subjects have nothing marked yet this term.
EOF
fi

echo "Made $vault (bots: school, coach, builder), $cache and $writer"
