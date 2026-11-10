// Bundles the whiteboard into ../../Resources/Whiteboard (index.html, board.js, chunks, fonts).
// Excalidraw is bundled as ES modules with code splitting, so languages and rarely used parts
// load only when needed. Fonts are copied next to the bundle: the web view has no network.
import { build } from 'esbuild'
import { cpSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, '../../Resources/Whiteboard')
rmSync(out, { recursive: true, force: true })
mkdirSync(out, { recursive: true })

await build({
  entryPoints: [join(here, 'src/main.tsx')],
  bundle: true,
  minify: true,
  sourcemap: false,
  format: 'esm',
  splitting: true,
  target: ['safari18'],
  outdir: out,
  entryNames: 'board',
  chunkNames: 'chunks/[name]-[hash]',
  assetNames: 'assets/[name]-[hash]',
  conditions: ['production'],
  loader: { '.woff2': 'file', '.png': 'dataurl', '.svg': 'dataurl' },
  jsx: 'automatic',
  define: { 'process.env.NODE_ENV': '"production"', 'process.env.IS_PREACT': '"false"' },
  logLevel: 'warning',
})

// Excalidraw's fonts (window.EXCALIDRAW_ASSET_PATH points here). Xiaolai (Chinese, 12 MB) is left
// out: those characters fall back to the system font.
const fonts = join(here, 'node_modules/@excalidraw/excalidraw/dist/prod/fonts')
for (const family of readdirSync(fonts)) {
  if (family === 'Xiaolai') continue
  cpSync(join(fonts, family), join(out, 'fonts', family), { recursive: true })
}

writeFileSync(join(out, 'index.html'), `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: blob:; connect-src 'self' data: blob:">
<link rel="stylesheet" href="board.css">
<style>html,body,#root{margin:0;height:100%;overflow:hidden}</style>
</head><body><div id="root"></div><script type="module" src="board.js"></script></body></html>
`)
console.log('Built', out)
