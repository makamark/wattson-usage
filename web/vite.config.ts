import { defineConfig } from 'vite'
export default defineConfig({
  // dev 模式下 /api 代理到本机 agg-server；build 产物由 agg-server 直接托管，无需代理。
  server: { proxy: { '/api': 'http://127.0.0.1:8317' } },
  build: { target: 'es2022' },
})
