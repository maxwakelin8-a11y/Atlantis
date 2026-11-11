# Issues

Log problems the moment you hit them. One line each. Ideas go to PRD §7 "Later", not here.

Format: `- [ ] [bug|polish|perf] what happened · where · YYYY-MM-DD`

## Open

- [ ] [bug] Files with old Mac line endings (CR only) don't survive the block splice; safe today because unedited docs are never written · Docs · 2026-11-06
- [ ] [bug] The Writer saves over a doc that another app changed while it was open (it reloads changes only when the page becomes visible); add an mtime check to `store.save` · Docs · 2026-11-07
- [ ] [polish] Writer features that need Claude (spelling & grammar, reference from a link) or SEQTA ("From a SEQTA assessment") show "comes later" messages · Docs · 2026-11-07
- [ ] [perf] PDF export runs headless Helium/Chrome (as the BetterSEQTA+ Writer did; WebKit can't print page numbers); background networking is switched off with flags · Docs · 2026-11-07
- [ ] [polish] vitest (dev only) still has npm audit advisories (tinypool, @vitest/mocker); fix needs vitest 5 · Docs build · 2026-11-07
- [ ] [polish] Mermaid/WaveDrom diagrams show as code (renderers not bundled) · Docs · 2026-11-06
- [ ] [polish] Editor CSS uses GenOffice's tokens; switch to Atlantis tokens with the design system · Docs · 2026-11-06

- [ ] [perf] The SEQTA tab's web view has open network access (needed for sign-in and BetterSEQTA+); goes away with the tab in M4b (PRD §7d) · SEQTA · 2026-11-06

- [ ] [polish] File chooser (copied from seqta-app) uses raw spacing and colours; move to tokens when the design system lands · SEQTA · 2026-11-06

- [ ] [polish] Haiku 5.5 helpers stop before doing any work in this repo ("context refilled too quickly after compaction", twice); use Sonnet/Opus helpers here · Tooling · 2026-11-09

- [ ] [bug] SEQTA sync never run against real SEQTA: check sign-in sharing, the signed-out reply, the SEQTA-only network rule, assessment detail/feedback field names · SEQTA · 2026-11-10
- [ ] [bug] Messages: message bodies, staff/student people lists, file downloads, the real send request and "Open in SEQTA" links are untested live · Messages/Subjects · 2026-11-10
- [ ] [polish] Subjects/Messages dark mode headers may render white-on-white; sidebar sub-items not seen in a real screenshot · Subjects/Messages · 2026-11-10
- [ ] [polish] Homework proposals use the lesson date as due date (SEQTA gives none) · Today/Inbox · 2026-11-10
- [ ] [polish] App doesn't add a `machine/log/` entry after writing the daily note (vault rule is for scripts/agents; decide) · Today · 2026-11-10
- [ ] [polish] Tasks: J/K/Space/Esc and the Inbox keys/edit sheet not tried by hand; recurring tasks, `scheduled::` time editing and the global quick-add hotkey not built · Tasks/Inbox · 2026-11-10
- [ ] [perf] TaskStore reads/writes on the main actor; an iCloud file that isn't downloaded could block the UI briefly · Tasks · 2026-11-10
- [ ] [polish] Inbox never prunes `inbox.md`; Done shows the latest 50; lines without an id are hidden · Inbox · 2026-11-10
- [ ] [polish] Docs: pasted image alt text is the clipboard file name; search matches raw markdown (misses across formatting) · Docs · 2026-11-10
- [ ] [polish] MCP: a tools/call sent before the initialize reply is tagged `mcp` not `mcp:<client>`; a force-quit leaves the socket file until next launch · MCP · 2026-11-10
- [ ] [polish] Agents: one run at a time across all bots; threads can't be renamed/deleted; bots re-look-up data each message; thread list reads every file on open · Agents · 2026-11-10
- [ ] [polish] Existing bot files keep old triggers: add `task`/`mention` to school.md, `schedule morning` + `event task.overdue` to coach.md, `event seqta.assessment.new` + `atlantis_task_add` to school.md to use M6/M7 features · Agents · 2026-11-10
- [ ] [bug] Queued bot runs are dropped when the app quits; the first sync of the day starts the morning plan even if it's an afternoon refresh · Agents · 2026-11-10
- [ ] [polish] Inbox titles for Chief's hand-offs repeat Chief's request and can be long · Agents/Inbox · 2026-11-10
- [ ] [polish] Debug screenshots taken while the Mac is asleep/locked have a blank sidebar (fallback drawing) · Tooling · 2026-11-10
- [ ] [bug] Docs editor has no web-process crash handler: if the editor's web process dies, Docs stays blank until restart; reloading needs care because of unsaved text · Docs · 2026-11-11
- [ ] [bug] `ATLANTIS_DOCS_PROBE` runs JavaScript from an environment variable in the Docs page in release builds; should be a debug-only option · App · 2026-11-11
- [ ] [bug] Docs export checks only that the target file exists afterwards, so a failed export over an existing file can look like success (not reproduced) · Docs · 2026-11-11
- [ ] [perf] Today uses `TimelineView(.everyMinute)` while visible; decide whether it fits "no repeating timers" · Today · 2026-11-11
- [ ] [bug] The SEQTA tab builds its own `WKWebViewConfiguration` instead of `WebViews.configuration(network: .open)`, against the "every web view through WebViews" rule · SEQTA · 2026-11-11

## Fixed

- [x] [bug] Docs editor text and menus were in Chinese (GenOffice defaults to zh) → English now · Docs · 2026-11-07
- [x] [polish] Docs had no toolbar, slash or table menus → it's the Writer now (format bar, "/" menu, table menu) · Docs · 2026-11-07
- [x] [bug] Quitting hung while Docs was open (save-before-quit waited on WebKit in `.terminateLater`) → save first, then quit, with a 3 s cap · App · 2026-11-07

- [x] [bug] `scripts/build-app.sh` never built the app (`swift build` keeps only the last `--product`), so the installed app stayed on the 7 Nov build; helper test copies were left running with windows stacked on the real one → one product per call; test copies closed · Tooling · 2026-11-10
- [x] [bug] Sidebar rows Today, Tasks, Inbox, Messages, Agents and Docs couldn't be clicked (`.badge` after `.tag` dropped the row's tag) → `.tag` goes last · Sidebar · 2026-11-10
- [x] [perf] SEQTA web view stayed loaded after leaving its page → now unloads after 10 min hidden · SEQTA · 2026-11-06
