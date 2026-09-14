import { defineConfig } from 'vitest/config'
import { fileURLToPath } from 'node:url'
export default defineConfig({
  resolve: { alias: { '@codeburn': fileURLToPath(new URL('../codeburn/src', import.meta.url)) } },
  test: { include: ['tests/**/*.test.ts'] },
})
