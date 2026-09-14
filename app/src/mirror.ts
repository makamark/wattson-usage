// app/src/mirror.ts — 远端镜像编排：spawn sync/mirror.sh（AGG_CONFIG 指向客户端配置），
// 应用运行期间每 30 分钟一轮（与 launchd 版 cadence 一致）；状态/日志经回调上抛，
// 驱动小窗「同步中」chip 与设置页的实时日志。
// mirror.sh 结束时会输出机器可读汇总行「ROUND RESULT devices=N ok=X failed=Y
// skipped=Z busy=W」，本类解析后存入 lastSummary 并触发 onRoundDone（整轮终态），
// 上层据此驱动「同步完成 → 触发采集」的依赖链。
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { CONFIG_PATH, MIRROR_SCRIPT } from './config'

export type MirrorState = {
  running: boolean
  lastAt: number | null
  lastCode: number | null
  /** 最近一轮的 ROUND RESULT 汇总行（mirror.sh 的机器可读终态），无远端设备时也可能是 undefined */
  lastSummary?: string
}

const MIRROR_INTERVAL_MIN = 30
const ROUND_RESULT_RE = /ROUND RESULT devices=\d+ ok=\d+ failed=\d+ skipped=\d+ busy=\d+/

export class Mirror {
  private child: ChildProcess | null = null
  private timer: NodeJS.Timeout | null = null
  private roundSummary: string | undefined
  state: MirrorState = { running: false, lastAt: null, lastCode: null }

  constructor(
    private readonly onLog: (line: string) => void,
    private readonly onState: (s: MirrorState) => void,
    /** 每轮同步前现取设备表（"name\tssh" 行），注入 MIRROR_DEVICES 免去 mirror.sh 调 python3 */
    private readonly devices: () => string,
    /** 整轮终态回调（进程退出即调用，code=mirror.sh 退出码；0 = 全部设备完成） */
    private readonly onRoundDone: (code: number | null) => void = () => undefined,
  ) {}

  /** 手动/定时触发一轮；已在跑则返回 false（mirror.sh 自身还有 .lock 兜底） */
  run(): boolean {
    if (this.child) return false
    if (!existsSync(MIRROR_SCRIPT)) {
      this.onLog(`[mirror] 未找到镜像脚本: ${MIRROR_SCRIPT}（打包不完整？）`)
      return false
    }
    // GUI 应用 PATH 极简，但 mirror.sh 内部自行收紧到系统路径；MIRROR_DEVICES
    // 让设备解析零外部解释器（全新 Mac 无 python3 弹窗）。
    // detached=true 让 bash 成为进程组长：退出时 kill(-pid) 可连带回收
    // 它派生的 ssh/rsync 子进程，不遗留半途传输。
    const child = spawn('/bin/bash', [MIRROR_SCRIPT], {
      env: { ...process.env, AGG_CONFIG: CONFIG_PATH, MIRROR_DEVICES: this.devices() },
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    })
    this.child = child
    this.roundSummary = undefined
    this.set({ running: true })
    const pump = (stream: NodeJS.ReadableStream | null) => {
      if (!stream) return
      let buf = ''
      stream.setEncoding('utf8')
      stream.on('data', (chunk: string) => {
        buf += chunk
        const lines = buf.split('\n')
        buf = lines.pop() ?? ''
        for (const line of lines) {
          if (!line.trim()) continue
          const m = ROUND_RESULT_RE.exec(line)
          if (m) this.roundSummary = m[0]
          this.onLog(line)
        }
      })
    }
    pump(child.stdout)
    pump(child.stderr)
    child.on('error', (err) => {
      this.onLog(`[mirror] 启动失败: ${err.message}`)
      this.child = null
      this.set({ running: false })
    })
    child.on('close', (code) => {
      this.child = null
      this.set({ running: false, lastAt: Date.now(), lastCode: code ?? -1, lastSummary: this.roundSummary })
      this.onRoundDone(code ?? -1)
    })
    return true
  }

  /** 应用启动即调：定时轮转（配置无远端设备时 mirror.sh 会自己记一行无事可做） */
  startSchedule(): void {
    this.stopSchedule()
    this.timer = setInterval(() => this.run(), MIRROR_INTERVAL_MIN * 60 * 1000)
  }

  stopSchedule(): void {
    if (this.timer) { clearInterval(this.timer); this.timer = null }
  }

  /** 退出应用时终止进行中的一轮：向整个进程组发 SIGTERM（rsync 半途终止无害：
   *  快照原子替换，下一轮自愈），再兜底杀单个 bash。 */
  stop(): void {
    this.stopSchedule()
    const child = this.child
    if (!child) return
    if (child.pid) {
      try { process.kill(-child.pid, 'SIGTERM') } catch { /* 组已退出 */ }
    }
    child.kill()
  }

  private set(patch: Partial<MirrorState>): void {
    this.state = { ...this.state, ...patch }
    this.onState(this.state)
  }
}
