// Bundles the editor into ../../Resources/DocsEditor (index.html, editor.js, editor.css).
import { build } from 'esbuild'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const out = join(here, '../../Resources/DocsEditor')
mkdirSync(out, { recursive: true })

const result = await build({
  entryPoints: [join(here, 'src/entry.tsx')],
  bundle: true,
  minify: true,
  sourcemap: false,
  format: 'iife',
  target: ['safari18'],
  outfile: join(out, 'editor.js'),
  // WebKit uses the woff2 fonts; the older formats are dropped to keep the bundle small.
  loader: { '.png': 'dataurl', '.woff2': 'file', '.woff': 'empty', '.ttf': 'empty' },
  assetNames: 'assets/[name]-[hash]',
  jsx: 'automatic',
  define: { 'process.env.NODE_ENV': '"production"' },
  metafile: true,
  logLevel: 'warning',
  plugins: [stubs()],
})

writeFileSync(join(out, 'index.html'), `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: atlantis-asset:; font-src 'self' data:">
<link rel="stylesheet" href="editor.css">
</head><body><div id="root"></div><script src="editor.js"></script></body></html>
`)
writeFileSync(join(here, 'meta.json'), JSON.stringify(result.metafile))
console.log('Built', out)

// Modules the vendored code imports that Atlantis doesn't ship (AI, Electron, export engines).
function stubs() {
  const v = join(here, 'vendor/genoffice/packages')
  const alias = {
    '@genoffice/ui': join(here, 'src/shims/genoffice-ui.ts'),
    '@genoffice/i18n': join(v, 'i18n/index.ts'),
    '@genoffice/agent-core/redact-core': join(v, 'agent-core/redact-core.ts'),
    '@genoffice/agent-core/redact-range': join(v, 'agent-core/redact-range.ts'),
    mermaid: join(here, 'src/shims/no-diagrams.ts'),
    wavedrom: join(here, 'src/shims/no-diagrams.ts'),
    json5: join(here, 'src/shims/no-diagrams.ts'),
  }
  return {
    name: 'atlantis-stubs',
    setup(b) {
      b.onResolve({ filter: /^(@genoffice\/|mermaid$|wavedrom$|json5$)/ }, (args) => {
        const path = alias[args.path]
        if (!path) return { errors: [{ text: `Not vendored: ${args.path}` }] }
        return { path }
      })
      b.onResolve({ filter: /\?inline$/ }, (args) => ({ path: args.path.replace(/\?inline$/, ''), namespace: 'inline-css', pluginData: args.resolveDir }))
    },
  }
}
