#!/bin/zsh
# Makes a made-up LifeOS vault and SEQTA cache dated today, for trying the Today page without
# touching the real vault or SEQTA. Everything here is invented.
#
#   scripts/today-fixture.sh [vault-dir] [cache-dir]     (defaults: /tmp/today-vault /tmp/today-seqta)
#   .build/debug/Atlantis -vaultPath /tmp/today-vault -debugSeqtaCache /tmp/today-seqta \
#       -debugPlanPath /tmp/today-plan.json -debugPage today [-debugNow 10:05]
#
# Pass --empty to make an empty vault and no cache (the first-run look).
set -euo pipefail

empty=0
if [[ "${1:-}" == "--empty" ]]; then empty=1; shift; fi
vault="${1:-/tmp/today-vault}"
cache="${2:-/tmp/today-seqta}"

rm -rf "$vault" "$cache"
mkdir -p "$vault/machine/atlantis" "$vault/daily" "$vault/human/[98] System/Templates"

cat > "$vault/human/[98] System/Templates/journal-template.md" <<'EOF'
---
type: Journal
date: {{date}}
classes: []
assessments_due: []
notices: []
synced_at:
bjj:
tasks: []
mood:
---

# {{title}}

<!-- machine:start (written by the morning sync; edits here are overwritten) -->
_Not synced yet._
<!-- machine:end -->

## Top 3

1.
2.
3.

## Notes

EOF

if (( empty )); then
  echo "Empty vault at $vault (no SEQTA cache)"
  exit 0
fi

day() { date -v"${1}"d +%Y-%m-%d; }
today=$(day +0)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

sed -e "s/{{date}}/$today/; s/{{title}}/$today/" -e 's/^1\. *$/1. Finish the bridge essay plan/' \
    -e 's/^2\. *$/2. Revise chapter 3 for the quiz/' \
    "$vault/human/[98] System/Templates/journal-template.md" > "$vault/daily/$today.md"

cat > "$vault/machine/tasks.md" <<EOF
# Tasks

- [ ] Return library book [due:: $(day -2)] [area:: School] ^t-0000a001
- [ ] Maths worksheet 4B [due:: $today] [project:: Maths] [area:: School] [pri:: 1] ^t-0000a002
- [ ] Email coach about Saturday [plan:: $today] [mode:: bjj] ^t-0000a003
- [ ] Essay plan: bridge design [scheduled:: ${today}T16:00] [est:: 45m] [project:: English] ^t-0000a004
- [ ] Pack sports uniform [scheduled:: $today] ^t-0000a005
- [ ] Science poster draft [due:: $(day +3)] [project:: Science] ^t-0000a006
EOF

mkdir -p "$cache"
lesson() { # date from until code subject room teacher colour topic homework
  local topic="" homework=""
  [[ -n "$9" ]] && topic=", \"topic\": \"$9\""
  [[ -n "${10}" ]] && homework=", \"homework\": \"${10}\""
  print -r -- "    { \"id\": \"$1T$2-$4\", \"date\": \"$1\", \"from\": \"$2\", \"until\": \"$3\", \"code\": \"$4\", \"subject\": \"$5\", \"room\": \"$6\", \"teacher\": \"$7\", \"colour\": \"$8\", \"type\": \"class\"$topic$homework }"
}
{
  print "{ \"version\": 1, \"syncedAt\": \"$now\", \"items\": ["
  lesson "$today" 08:40 08:55 CARE9 "Care Group" A01 "Mx Rivers" "#8e8e93" "" "" ; print ","
  lesson "$today" 08:55 09:40 SCI9 Science L02 "Dr Patel" "#34c759" "Forces and motion" "" ; print ","
  lesson "$today" 09:40 10:25 HIS9 History H01 "Mr Gray" "#ff9500" "Bridges of the industrial age" "Finish the source table" ; print ","
  lesson "$today" 11:00 11:45 ENG9 English E04 "Ms Lane" "#007aff" "Persuasive openings" "" ; print ","
  lesson "$today" 11:45 12:30 ENG9 English E04 "Ms Lane" "#007aff" "" "Read chapter 3" ; print ","
  lesson "$today" 13:15 14:00 MAT9 Maths M03 "Mrs Chen" "#af52de" "Linear equations" "Worksheet 4B" ; print ","
  lesson "$today" 14:00 14:45 ART9 "Visual Art" V01 "Mr Okafor" "#ff2d55" "" "" ; print ","
  lesson "$(day +1)" 08:55 09:40 MAT9 Maths M03 "Mrs Chen" "#af52de" "Graphing lines" ""
  print "] }"
} > "$cache/lessons.json"

cat > "$cache/assessments.json" <<EOF
{ "version": 1, "syncedAt": "$now", "items": [
  { "id": 9001, "title": "Bridge design essay", "subject": "English", "code": "ENG9", "due": "$(day +1)", "status": "PENDING", "submitted": false },
  { "id": 9002, "title": "Forces practical report", "subject": "Science", "code": "SCI9", "due": "$(day +3)", "status": "PENDING", "submitted": false },
  { "id": 9003, "title": "Industrial age source analysis", "subject": "History", "code": "HIS9", "due": "$(day +8)", "status": "PENDING", "submitted": false },
  { "id": 9004, "title": "Linear equations test", "subject": "Maths", "code": "MAT9", "due": "$(day +13)", "status": "PENDING", "submitted": false },
  { "id": 9005, "title": "Self portrait", "subject": "Visual Art", "code": "ART9", "due": "$(day -5)", "status": "MARKS_RELEASED", "submitted": true }
] }
EOF

cat > "$cache/notices.json" <<EOF
{ "version": 1, "syncedAt": "$now", "items": [
  { "id": 501, "date": "$today", "title": "Sports carnival on Friday", "label": "Year 9", "staff": "Mx Field", "contents": "Wear your house colours and bring a water bottle." },
  { "id": 502, "date": "$today", "title": "Library open at lunch", "label": "All students", "staff": "Ms Page", "contents": "New books are on the front shelf." }
] }
EOF

cat > "$cache/subjects.json" <<EOF
{ "version": 1, "syncedAt": "$now", "items": [
  { "code": "ENG9", "name": "English", "colour": "#007aff", "teacher": "Ms Lane", "programme": 1, "metaclass": 11 },
  { "code": "SCI9", "name": "Science", "colour": "#34c759", "teacher": "Dr Patel", "programme": 2, "metaclass": 12 },
  { "code": "HIS9", "name": "History", "colour": "#ff9500", "teacher": "Mr Gray", "programme": 3, "metaclass": 13 },
  { "code": "MAT9", "name": "Maths", "colour": "#af52de", "teacher": "Mrs Chen", "programme": 4, "metaclass": 14 }
] }
EOF

cat > "$cache/meta.json" <<EOF
{ "version": 1, "lastSync": "$now", "lastReason": "manual", "kinds": {}, "failures": {}, "newMarkAssessmentIDs": [] }
EOF

echo "Made-up vault at $vault and SEQTA cache at $cache (dated $today)"
