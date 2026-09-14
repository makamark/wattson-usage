// app/scripts/gen-tray.js — 生成托盘 template 图标（16/32px，纯黑+alpha）。
// qlmanage 对纯黑形状的 SVG 渲染会得到空图，改为按几何直接写像素并手工编码 PNG（仅依赖系统 node:zlib）。
// 用法：node app/scripts/gen-tray.js
import { deflateSync } from 'node:zlib'
import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'build')

function crc32(buf) {
  let c, table = []
  for (let n = 0; n < 256; n++) {
    c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  let crc = 0xffffffff
  for (const b of buf) crc = table[(crc ^ b) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

function png(width, height, rgba) {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body))
    return Buffer.concat([len, body, crc])
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8; ihdr[9] = 6 // 8-bit RGBA
  const raw = Buffer.alloc(height * (1 + width * 4))
  for (let y = 0; y < height; y++) {
    raw[y * (1 + width * 4)] = 0 // filter: none
    rgba.copy(raw, y * (1 + width * 4) + 1, y * width * 4, (y + 1) * width * 4)
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ])
}

// 闪电 template（黑色 + 抗锯齿 alpha）。几何与 build/trayTemplate.svg / web/src/icons.ts
// 同一 bolt（16 栅格 ×1.7 居中进 32 盒），点在多边形内判定（射线法）+ 4x 超采样。
const BOLT = [
  [8.8, 1.2], [3, 9.4], [6.8, 9.4], [6.4, 14.8], [13, 6.4], [9, 6.4],
]
const SCALE = 1.7
const OFF = [
  (32 - (13 - 3) * SCALE) / 2 - 3 * SCALE,
  (32 - (14.8 - 1.2) * SCALE) / 2 - 1.2 * SCALE,
]

function pointInBolt(px, py) {
  let inside = false
  for (let i = 0, j = BOLT.length - 1; i < BOLT.length; j = i++) {
    const [xi, yi] = BOLT[i], [xj, yj] = BOLT[j]
    if ((yi > py) !== (yj > py) &&
      px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) inside = !inside
  }
  return inside
}

function render(size) {
  const s = size / 32
  const rgba = Buffer.alloc(size * size * 4)
  // 4x 超采样抗锯齿
  const SS = 4
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let hit = 0
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const px = (x + (sx + 0.5) / SS) / s, py = (y + (sy + 0.5) / SS) / s
          // 32 盒坐标 → 16 栅格 bolt 坐标
          if (pointInBolt((px - OFF[0]) / SCALE, (py - OFF[1]) / SCALE)) hit++
        }
      }
      const a = Math.round(hit / (SS * SS) * 255)
      const i = (y * size + x) * 4
      rgba[i] = 0; rgba[i + 1] = 0; rgba[i + 2] = 0; rgba[i + 3] = a
    }
  }
  return rgba
}

for (const size of [16, 32]) {
  const file = join(OUT, size === 16 ? 'trayTemplate.png' : 'trayTemplate@2x.png')
  writeFileSync(file, png(size, size, render(size)))
  console.log('wrote', file)
}
