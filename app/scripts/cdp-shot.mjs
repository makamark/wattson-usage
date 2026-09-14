// app/scripts/cdp-shot.mjs — 极简 CDP 客户端：列目标 / 截图（依赖 Node 内置 fetch+WebSocket）。
// 用法：node cdp-shot.mjs <port> list
//       node cdp-shot.mjs <port> shot <targetId> <out.png> [evaluate:<js>]
const port = process.argv[2]
const cmd = process.argv[3]

const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()
if (cmd === 'list') {
  for (const t of targets) console.log(t.id, t.type, JSON.stringify(t.title), t.url)
  process.exit(0)
}

const target = targets.find((t) => t.id === process.argv[4])
if (!target) { console.error('target not found'); process.exit(1) }

const ws = new WebSocket(target.webSocketDebuggerUrl)
const pending = new Map()
let seq = 0
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++seq
  pending.set(id, { resolve, reject })
  ws.send(JSON.stringify({ id, method, params }))
})
ws.onmessage = (ev) => {
  const msg = JSON.parse(ev.data)
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id)
    pending.delete(msg.id)
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result)
  }
}
await new Promise((r) => { ws.onopen = r })

await send('Page.enable')
await send('Runtime.enable')
// 等渲染层就绪（隐藏窗口 rAF 不触发，必须带超时兜底）
await Promise.race([
  send('Runtime.evaluate', { expression: 'new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))', awaitPromise: true }),
  new Promise((r) => setTimeout(r, 1500)),
])
if (process.argv[6]?.startsWith('evaluate:')) {
  const res = await send('Runtime.evaluate', { expression: process.argv[6].slice(9), returnByValue: true })
  console.log(JSON.stringify(res.result?.value ?? res.result, null, 2))
}
const shot = await send('Page.captureScreenshot', { format: 'png' })
const { writeFileSync } = await import('node:fs')
writeFileSync(process.argv[5], Buffer.from(shot.data, 'base64'))
console.log('saved', process.argv[5])
ws.close()
