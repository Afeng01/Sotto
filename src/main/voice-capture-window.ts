/**
 * 听写采集窗口生命周期
 *
 * 独立应用只有这一个听写窗口：非聚焦、置顶、透明，位于光标所在屏幕底部居中。
 * 独立应用的唯一听写窗口，相当于"非聚焦状态条"——
 * 音频采集（getUserMedia）不需要窗口焦点，因此可以在不抢走目标应用焦点的前提下完成听写。
 */

import { app, BrowserWindow, screen, type BrowserWindowConstructorOptions } from 'electron'
import { join } from 'node:path'
import { VOICE_DICTATION_IPC_CHANNELS } from '@sotto/voice'

const CAPTURE_WIDTH = 380
const CAPTURE_MIN_HEIGHT = 110
const CAPTURE_BOTTOM_MARGIN = 28

type CaptureLifecycleState = 'idle' | 'active' | 'stopping'

let captureState: CaptureLifecycleState = 'idle'
let captureWindow: BrowserWindow | null = null

export function isCaptureActive(): boolean {
  return captureState !== 'idle'
}

export function debugCaptureState(): string {
  const win = captureWindow && !captureWindow.isDestroyed() ? captureWindow : null
  return `state=${captureState} window=${win ? (win.isVisible() ? 'visible' : 'hidden') : 'none'}`
}

/** 快捷键入口：唤起听写浮窗；录音中再次触发则通知 renderer 停止提交。 */
export function toggleCaptureWindow(): void {
  // 未启用/未配置凭证时也弹窗：由 renderer 展示原因与“打开设置”入口，
  // 静默忽略会让用户以为快捷键坏了。
  console.log('[听写] toggle 入口，', debugCaptureState())
  if (captureState === 'stopping') {
    // 停止/提交尚未完成时忽略重复触发，避免旧会话与新会话交叉。
    return
  }

  if (captureState === 'active') {
    captureState = 'stopping'
    console.log('[听写] 发送停止指令')
    captureWindow?.webContents.send(VOICE_DICTATION_IPC_CHANNELS.TOGGLE_STOP)
    return
  }

  captureState = 'active'
  const win = getOrCreateCaptureWindow()
  // ready-to-show 只在首次加载时触发一次；复用已有窗口时必须主动重新显示，
  // 否则会话在后台跑、浮窗永远不再出现。
  if (!win.isVisible()) {
    positionCaptureWindow(win)
    win.showInactive()
    console.log('[听写] 重新显示浮窗，', debugCaptureState())
  }
  sendShownEvent(win)
}

function sendShownEvent(win: BrowserWindow): void {
  win.webContents.send(VOICE_DICTATION_IPC_CHANNELS.SHOWN, {
    externalOutput: false,
    outputContextId: 'standalone',
  })
}

/** renderer 提交/取消完成后调用：隐藏窗口并复位状态机 */
export function finishCaptureSession(): void {
  console.log('[听写] 会话结束，隐藏浮窗，', debugCaptureState())
  captureState = 'idle'
  if (captureWindow && !captureWindow.isDestroyed()) {
    captureWindow.hide()
  }
}

/** 供 renderer 的 STATE(error) 事件等场景强制复位 */
export function resetCaptureSession(): void {
  captureState = 'idle'
  if (captureWindow && !captureWindow.isDestroyed()) {
    captureWindow.hide()
  }
}

function getCaptureWindowOptions(): BrowserWindowConstructorOptions {
  return {
    width: CAPTURE_WIDTH,
    height: CAPTURE_MIN_HEIGHT,
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    alwaysOnTop: true,
    skipTaskbar: true,
    // 非聚焦：保持目标应用为前台，粘贴指令才能写进用户正在输入的位置。
    focusable: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    show: false,
    // 原生阴影在透明窗口 + 圆角卡片下会算出硬边轮廓线；阴影交给 CSS 画。
    hasShadow: false,
    webPreferences: {
      preload: join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  }
}

function getOrCreateCaptureWindow(): BrowserWindow {
  if (captureWindow && !captureWindow.isDestroyed()) return captureWindow

  const win = new BrowserWindow(getCaptureWindowOptions())
  captureWindow = win
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  win.on('closed', () => {
    if (captureWindow === win) captureWindow = null
  })

  // 放行麦克风采集（Electron 默认拒绝未声明的 media 权限请求链）。
  win.webContents.session.setPermissionRequestHandler((_wc, permission, callback) => {
    callback(permission === 'media')
  })
  win.webContents.session.setPermissionCheckHandler((_wc, permission) => permission === 'media')

  // 首次唤起时 renderer 尚未就绪会丢失 SHOWN 事件，加载完成后补发。
  win.webContents.on('did-finish-load', () => {
    console.log('[听写] 采集窗口加载完成，', debugCaptureState())
    if (captureState === 'active' && !win.isDestroyed()) {
      sendShownEvent(win)
    }
  })

  if (!app.isPackaged) {
    // dev：把浮窗 renderer 的 console 转发到主进程日志，便于自动化排查。
    win.webContents.on('console-message', (_event, _level, message) => {
      console.log('[浮窗]', message)
    })
  }

  // resize IPC 会动态调整高度；位置保持底部居中。
  win.on('ready-to-show', () => {
    positionCaptureWindow(win)
    win.showInactive()
  })

  if (app.isPackaged) {
    void win.loadFile(join(__dirname, 'renderer', 'index.html'), {
      query: { window: 'voice-capture' },
    })
  } else {
    void win.loadURL('http://127.0.0.1:5174?window=voice-capture')
  }

  return win
}

function positionCaptureWindow(win: BrowserWindow): void {
  const point = screen.getCursorScreenPoint()
  const display = screen.getDisplayNearestPoint(point)
  const { x, y, width, height } = display.workArea
  const bounds = win.getBounds()
  win.setBounds({
    x: x + Math.round((width - bounds.width) / 2),
    y: y + height - bounds.height - CAPTURE_BOTTOM_MARGIN,
    width: bounds.width,
    height: bounds.height,
  })
}

/** renderer 请求按内容高度调整窗口；保持底部对齐，高度不超过可用区域的 1/3。 */
export function resizeCaptureWindow(height: number): void {
  if (!captureWindow || captureWindow.isDestroyed()) return
  const point = screen.getCursorScreenPoint()
  const display = screen.getDisplayNearestPoint(point)
  const { x, y, width, height: workHeight } = display.workArea
  const screenCap = Math.max(CAPTURE_MIN_HEIGHT, Math.floor((workHeight - CAPTURE_BOTTOM_MARGIN) / 3))
  const clamped = Math.max(CAPTURE_MIN_HEIGHT, Math.min(560, screenCap, Math.round(height)))
  const bounds = captureWindow.getBounds()
  if (bounds.height === clamped) return
  captureWindow.setBounds({
    x: x + Math.round((width - bounds.width) / 2),
    y: y + workHeight - clamped - CAPTURE_BOTTOM_MARGIN,
    width: bounds.width,
    height: clamped,
  })
}

export function destroyCaptureWindow(): void {
  if (captureWindow && !captureWindow.isDestroyed()) {
    captureWindow.destroy()
  }
  captureWindow = null
  captureState = 'idle'
}
