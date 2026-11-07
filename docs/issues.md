# Issues

Log problems the moment you hit them. One line each. Ideas go to PRD §7 "Later", not here.

Format: `- [ ] [bug|polish|perf] what happened · where · YYYY-MM-DD`

## Open

- [ ] [bug] Files with old Mac line endings (CR only) don't survive the block splice; safe today because unedited docs are never written · Docs · 2026-11-06
- [ ] [polish] Docs hides front matter (kept in the file) and has no slash/table menus yet; copy those from the GenOffice snapshot in M1 · Docs · 2026-11-06
- [ ] [polish] Mermaid/WaveDrom diagrams show as code (renderers not bundled) · Docs · 2026-11-06
- [ ] [polish] Editor CSS uses GenOffice's tokens; switch to Atlantis tokens with the design system · Docs · 2026-11-06

- [ ] [perf] The SEQTA tab's web view has open network access (needed for sign-in and BetterSEQTA+); goes away with the tab in M4b (PRD §7d) · SEQTA · 2026-11-06

- [ ] [polish] File chooser (copied from seqta-app) uses raw spacing and colours; move to tokens when the design system lands · SEQTA · 2026-11-06

## Fixed

- [x] [perf] SEQTA web view stayed loaded after leaving its page → now unloads after 10 min hidden · SEQTA · 2026-11-06
