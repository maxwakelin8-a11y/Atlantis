import { defineConfig } from 'vitest/config'
import { fileURLToPath } from 'node:url'

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url))
const noDiagrams = here('./src/shims/no-diagrams.ts')

export default defineConfig({
  resolve: {
    alias: {
      '@genoffice/ui': here('./src/shims/genoffice-ui.ts'),
      '@genoffice/i18n': here('./vendor/genoffice/packages/i18n/index.ts'),
      '@genoffice/agent-core/redact-core': here('./vendor/genoffice/packages/agent-core/redact-core.ts'),
      '@genoffice/agent-core/redact-range': here('./vendor/genoffice/packages/agent-core/redact-range.ts'),
      mermaid: noDiagrams,
      wavedrom: noDiagrams,
      json5: noDiagrams,
    },
  },
  test: {
    include: ['test/**/*.test.ts'],
    environment: 'jsdom',
    testTimeout: 120000,
  },
})
