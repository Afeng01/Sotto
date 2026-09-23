/**
 * Sotto（呦呦） 主进程入口
 *
 * 菜单栏常驻应用：托盘 + 全局快捷键 + 听写采集窗口 + 设置窗口。
 * 常驻菜单栏 + Dock 图标（点击 Dock 图标打开设置），不加载任何 Agent 运行时。
 */

import { app, BrowserWindow, dialog, ipcMain, Menu, type Tray } from 'electron'
import { join } from 'node:path'
import { createTray, destroyTray, refreshTrayMenu, type TrayDeps } from './tray'
import { registerVoiceIpcHandlers, VOICE_APP_IPC_CHANNELS, registerSettingsChangedCallback } from './ipc'
import { registerVoiceHotkey, unregisterVoiceHotkey } from './shortcuts'
import { toggleCaptureWindow } from './voice-capture-window'
import { applyLoginItemSettings, getVoiceAppSettings, getVoiceDictationSettings } from './settings-store'
import { destroyCaptureWindow } from './voice-capture-window'

// 单实例：重复启动时聚焦已有进程，避免快捷键被抢占后双双失效。
if (!app.requestSingleInstanceLock()) {
  app.quit()
}

let quitting = false
let settingsWindow: BrowserWindow | null = null

function showSettingsWindow(): void {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show()
    settingsWindow.focus()
    return
  }
  settingsWindow = new BrowserWindow({
    width: 760,
    height: 640,
    minWidth: 660,
    minHeight: 520,
    title: '呦呦设置',
    show: false,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    trafficLightPosition: { x: 16, y: 16 },
    webPreferences: {
      preload: join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  })
  settingsWindow.once('ready-to-show', () => settingsWindow?.show())
  settingsWindow.on('closed', () => {
    settingsWindow = null
  })
  settingsWindow.on('close', (event) => {
    // 设置窗口关闭 = 隐藏，保持常驻听写可用。
    if (!quitting) {
      event.preventDefault()
      settingsWindow?.hide()
    }
  })
  if (app.isPackaged) {
    void settingsWindow.loadFile(join(__dirname, 'renderer', 'index.html'), {
      query: { window: 'settings' },
    })
  } else {
    void settingsWindow.loadURL('http://127.0.0.1:5174?window=settings')
  }
}

function getIconPath(): string {
  // dev：dist/main.cjs 同级的 ../resources；打包：app.asar/resources（files 中已包含）。
  return join(__dirname, '..', 'resources', 'icon.png')
}

function isVoiceConfigured(): boolean {
  const settings = getVoiceDictationSettings()
  return Boolean(settings.enabled && settings.appId && settings.accessToken)
}

function getTrayDeps(): TrayDeps {
  return {
    iconPath: getIconPath(),
    openSettings: showSettingsWindow,
    isConfigured: isVoiceConfigured,
    quit: () => app.quit(),
  }
}

async function bootstrap(): Promise<void> {
  // 显示 Dock 图标：用户可以从 Dock 点击唤起设置窗（activate 事件已接 showSettingsWindow）。

  // 独立应用没有主菜单，但需要标准编辑菜单支持设置页输入框快捷键。
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Sotto', submenu: [{ role: 'quit' }] },
    { label: '编辑', submenu: [{ role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
  ]))

  registerVoiceIpcHandlers()
  // 听写浮窗错误态的“打开设置”入口。
  ipcMain.on(VOICE_APP_IPC_CHANNELS.OPEN_SETTINGS_WINDOW, () => showSettingsWindow())
  applyLoginItemSettings(getVoiceAppSettings())

  createTray(getTrayDeps())

  // 设置保存后刷新托盘状态文案（凭证是否就绪）。
  registerSettingsChangedCallback(() => refreshTrayMenu(getTrayDeps()))

  const hotkeyOk = registerVoiceHotkey()
  const { hotkey } = getVoiceAppSettings()
  if (hotkey && !hotkeyOk) {
    // 静默失败会让用户以为“按了没反应”，这里必须把冲突暴露出来。
    void dialog.showMessageBox({
      type: 'warning',
      message: `全局听写快捷键 ${hotkey} 注册失败`,
      detail: '该快捷键可能被其他应用占用（例如其他应用占用了 Ctrl + `）。请在呦呦设置的“通用”页更换快捷键。',
      buttons: ['打开设置', '稍后处理'],
      defaultId: 0,
    }).then(({ response }) => {
      if (response === 0) showSettingsWindow()
    })
  }

  // 首次使用（未配置凭证）时主动打开设置窗口，避免用户找不到托盘入口。
  if (!isVoiceConfigured()) {
    showSettingsWindow()
  }

  // dev 专用调试钩子：kill -USR2 <pid> 模拟按一次全局快捷键，便于自动化验收。
  if (!app.isPackaged) {
    process.on('SIGUSR2', () => {
      console.log('[调试] SIGUSR2 触发听写开关')
      toggleCaptureWindow()
    })
  }

  app.on('activate', () => showSettingsWindow())
}

app.on('second-instance', () => showSettingsWindow())

app.whenReady().then(bootstrap).catch((error) => {
  console.error('[启动] bootstrap 失败:', error)
  dialog.showErrorBox('呦呦启动失败', error instanceof Error ? error.message : String(error))
})

app.on('before-quit', () => {
  quitting = true
  unregisterVoiceHotkey()
  destroyCaptureWindow()
  destroyTray()
})

app.on('window-all-closed', () => {
  // 常驻应用：窗口全部关闭（设置窗口隐藏、听写窗口销毁）不退出，由托盘退出。
})
