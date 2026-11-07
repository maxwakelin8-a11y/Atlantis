# GenOffice snapshot

A fixed copy of part of [GenOffice](https://github.com/genspark-ai/genoffice) (Apache-2.0, see
`LICENSE` and `NOTICE`). It is not tracked against upstream (PRD §15).

- Commit: `39374ebed6daf0680f8d520620c99d853a0a9b80` (2026-11-06)
- Copied 2026-11-06 for the M1 Docs spike.

## What's here

Only the files the Atlantis editor bundle actually uses (checked with esbuild's metafile):

- `renderer/editor/`, `renderer/markdown/`, `renderer/i18n/` and the stylesheets, from
  `apps/markdown/src/renderer`
- `shared/` helpers from `apps/markdown/src/shared`
- `packages/ui/`: dropdown, popover-dismiss, find-text, use-redact-label and the CSS
- `packages/i18n/`
- `packages/agent-core/`: `redact-core.ts` and `redact-range.ts` only (redaction marks are part of
  the saved markdown, so they're needed for the round trip; no AI code)

## What was left out

- All GenOffice AI (`renderer/ai/`, AI panels, `ai-provider`, `agent-core` loops and skills).
- The Electron main and preload layers. Atlantis replaces them with Swift and the narrow bridge
  in `src/bridge.ts`.
- Export engines (docx, image, print), the app shell UI, and the Mermaid and WaveDrom diagram
  renderers (stubbed in `src/shims/no-diagrams.ts`, so diagrams show as code).
- The `ee/` folder, which is never copied (different licence).

## Changes to the copied files

None. Atlantis code lives in `src/` and swaps out missing packages with aliases in `build.mjs`
and `vitest.config.ts`. To copy more (for example the slash or table menus), take them from the
same commit and record it here.
