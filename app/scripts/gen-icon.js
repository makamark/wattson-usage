// app/scripts/gen-icon.js — 从 build/icon.svg 重生成应用图标位图。
// 用法：node_modules/.bin/electron scripts/gen-icon.js   （需要 DOM/canvas，故跑在 Electron 里）
// 产出：build/icon.png（1024 主图）+ build/icon.iconset/*（iconutil 的输入），icns 由 iconutil 收尾。
// 渲染管线：SVG 以 4096（4x 超采样）drawImage 直渲（矢量光栅化，渐变/滤镜保真）→ 高质量缩到各尺寸。
// 注意：app 的 package.json 未标 "type":"module"，本脚本必须保持 CommonJS（import 语法会让
// Electron 启动即抛错并挂在一个不可见的错误对话框上）。
const { execFileSync } = require('node:child_process')
const { mkdirSync, readFileSync, rmSync, writeFileSync } = require('node:fs')
const { join } = require('node:path')
const { app, BrowserWindow } = require('electron')

const BUILD = join(__dirname, '..', 'build')
const SIZES = [16, 32, 64, 128, 256, 512, 1024]

async function main() {
  await app.whenReady()
  // 看门狗：渲染层挂起时 60s 强退，避免卡死终端
  const watchdog = setTimeout(() => { console.error('gen-icon 超时（60s）'); app.exit(1) }, 60_000)
  const win = new BrowserWindow({ show: false, width: 800, height: 600 })
  await win.loadURL('about:blank')
  const svg = readFileSync(join(BUILD, 'icon.svg'), 'utf8')
    .replace(/\n\s*<!--[\s\S]*?-->/g, '') // 去注释（data URL 里更稳妥）
  const url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg)
  const pngs = await win.webContents.executeJavaScript(`
    (async () => {
      const MASTER = 4096, SIZES = ${JSON.stringify(SIZES)}
      const img = new Image()
      img.decoding = 'sync'
      await new Promise((res, rej) => { img.onload = res; img.onerror = () => rej(new Error('SVG 加载失败')); img.src = ${JSON.stringify(url)} })
      const m = document.createElement('canvas')
      m.width = MASTER; m.height = MASTER
      const g = m.getContext('2d')
      g.imageSmoothingEnabled = true; g.imageSmoothingQuality = 'high'
      g.drawImage(img, 0, 0, MASTER, MASTER)
      const out = {}
      for (const size of SIZES) {
        const t = document.createElement('canvas')
        t.width = size; t.height = size
        const c = t.getContext('2d')
        c.imageSmoothingEnabled = true; c.imageSmoothingQuality = 'high'
        c.drawImage(m, 0, 0, size, size)
        out[size] = t.toDataURL('image/png')
      }
      return out
    })()
  `)
  clearTimeout(watchdog)
  const dir = join(BUILD, 'icon.iconset')
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(dir, { recursive: true })
  const names = {
    16: 'icon_16x16.png', 32: 'icon_16x16@2x.png',
    32: 'icon_32x32.png', 64: 'icon_32x32@2x.png',
    128: 'icon_128x128.png', 256: 'icon_128x128@2x.png',
    256: 'icon_256x256.png', 512: 'icon_256x256@2x.png',
    512: 'icon_512x512.png', 1024: 'icon_512x512@2x.png',
  }
  for (const size of SIZES) writeFileSync(join(dir, names[size]), Buffer.from(pngs[size].split(',')[1], 'base64'))
  writeFileSync(join(BUILD, 'icon.png'), Buffer.from(pngs[1024].split(',')[1], 'base64'))
  execFileSync('iconutil', ['-c', 'icns', dir, '-o', join(BUILD, 'icon.icns')])
  rmSync(dir, { recursive: true, force: true })
  console.log('icon.icns / icon.png 已从 icon.svg 重生成 →', BUILD)
  app.quit()
}

main().catch((err) => { console.error('gen-icon 失败:', err); app.exit(1) })
