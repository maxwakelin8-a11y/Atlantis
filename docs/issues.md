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

## Fixed

- [x] [bug] Docs editor text and menus were in Chinese (GenOffice defaults to zh) → English now · Docs · 2026-11-07
- [x] [polish] Docs had no toolbar, slash or table menus → it's the Writer now (format bar, "/" menu, table menu) · Docs · 2026-11-07
- [x] [bug] Quitting hung while Docs was open (save-before-quit waited on WebKit in `.terminateLater`) → save first, then quit, with a 3 s cap · App · 2026-11-07

- [x] [perf] SEQTA web view stayed loaded after leaving its page → now unloads after 10 min hidden · SEQTA · 2026-11-06
