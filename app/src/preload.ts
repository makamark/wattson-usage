// app/src/preload.ts — 小窗/向导共用的 contextBridge：渲染层零网络权限，
// 数据全部由主进程拉取后经 'state' 推送，动作经 invoke 回传。
import { contextBridge, ipcRenderer } from 'electron'

contextBridge.exposeInMainWorld('bridge', {
  onState: (cb: (s: unknown) => void): (() => void) => {
    const listener = (_e: Electron.IpcRendererEvent, s: unknown) => cb(s)
    ipcRenderer.on('state', listener)
    return () => ipcRenderer.removeListener('state', listener)
  },
  onMirrorLog: (cb: (line: string) => void): (() => void) => {
    const listener = (_e: Electron.IpcRendererEvent, line: string) => cb(line)
    ipcRenderer.on('mirror-log', listener)
    return () => ipcRenderer.removeListener('mirror-log', listener)
  },
  // 小窗动作
  refreshData: () => ipcRenderer.invoke('popup:refresh-data') as Promise<{ ok: boolean }>,
  openDashboard: () => ipcRenderer.invoke('popup:open-dashboard'),
  openSettings: () => ipcRenderer.invoke('popup:open-settings'),
  retryServer: () => ipcRenderer.invoke('popup:retry-server'),
  setRange: (range: string) => ipcRenderer.invoke('popup:set-range', range) as Promise<boolean>,
  // 向导
  wizGet: () => ipcRenderer.invoke('wiz:get') as Promise<Record<string, unknown>>,
  probeSsh: (dest: string) => ipcRenderer.invoke('wiz:probe-ssh', dest) as Promise<{
    ok: boolean; tools: string[]; missing: string[]; error?: string
  }>,
  saveConfig: (cfg: unknown) => ipcRenderer.invoke('wiz:save', cfg) as Promise<{
    ok: boolean; error?: string; restarted?: string
  }>,
  runMirror: () => ipcRenderer.invoke('wiz:run-mirror') as Promise<boolean>,
})

declare global {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  interface Window { bridge: any }
}
