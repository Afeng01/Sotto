/**
 * Sotto（呦呦） 主进程 IPC
 *
 * 语音通道复用 @sotto/voice 的 VOICE_DICTATION_IPC_CHANNELS；
 * 应用级通道（设置/导入/权限）为本应用自有。
 */

import { BrowserWindow, clipboard, ipcMain, systemPreferences } from 'electron'
import type { MicPermissionResult, VoiceDictationCommitResult } from '@sotto/voice'
import {
  VOICE_DICTATION_IPC_CHANNELS,
  type VoiceDictationAudioChunkInput,
  type VoiceDictationCommitInput,
  type VoiceDictationResizeInput,
  type VoiceDictationStartInput,
  type VoiceDictationStopInput,
} from '@sotto/voice'
import { cancelDoubaoAsrSession, pasteTextAtCurrentCursor, sendDoubaoAsrAudio, startDoubaoAsrSession, stopDoubaoAsrSession, testDoubaoAsrConnection } from '@sotto/voice/main'
import type { VoiceDictationSettings, VoiceDictationSettingsUpdate, VoiceAppSettings } from './settings-store'
import {
  applyLoginItemSettings,
  getVoiceAppSettings,
  getVoiceDictationSettings,
  updateVoiceDictationSettings,
} from './settings-store'
import { finishCaptureSession, isCaptureActive, resetCaptureSession, resizeCaptureWindow } from './voice-capture-window'
import { addHistoryEntry, clearHistory, deleteHistoryEntry, getHistoryEntries } from './history-store'

import { VOICE_APP_IPC_CHANNELS } from '../shared/ipc-channels'

export { VOICE_APP_IPC_CHANNELS } from '../shared/ipc-channels'

function assertString(value: unknown, field: string, maxLength = 4096): string {
  if (typeof value !== 'string') throw new Error(`${field} 必须是字符串`)
  return value.slice(0, maxLength)
}

function registerVoiceDictationHandlers(): void {
  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.GET_SETTINGS, (): VoiceDictationSettings =>
    getVoiceDictationSettings(),
  )

  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.UPDATE_SETTINGS,
    (_event, updates: VoiceDictationSettingsUpdate): VoiceDictationSettings => {
      if (!updates || typeof updates !== 'object') throw new Error('无效的设置更新')
      const safeUpdates: VoiceDictationSettingsUpdate = {}
      if (typeof updates.enabled === 'boolean') safeUpdates.enabled = updates.enabled
      if (typeof updates.appId === 'string') safeUpdates.appId = updates.appId.slice(0, 256)
      if (typeof updates.accessToken === 'string') safeUpdates.accessToken = updates.accessToken.slice(0, 4096)
      if (typeof updates.apiKey === 'string') safeUpdates.apiKey = updates.apiKey.slice(0, 4096)
      if (typeof updates.resourceId === 'string') safeUpdates.resourceId = updates.resourceId.slice(0, 256)
      if (typeof updates.language === 'string') safeUpdates.language = updates.language.slice(0, 64)
      if (updates.endpointMode === 'async' || updates.endpointMode === 'duplex') safeUpdates.endpointMode = updates.endpointMode
      if (updates.outputMode === 'auto' || updates.outputMode === 'clipboard') safeUpdates.outputMode = updates.outputMode
      if (typeof updates.customHotwords === 'string') safeUpdates.customHotwords = updates.customHotwords.slice(0, 8192)
      const next = updateVoiceDictationSettings(safeUpdates)
      notifySettingsChanged()
      return next
    },
  )

  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.TEST_CONNECTION, async () => {
    return testDoubaoAsrConnection(getVoiceDictationSettings())
  })

  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.START,
    async (event, input: VoiceDictationStartInput): Promise<void> => {
      const sessionId = assertString(input?.sessionId, 'sessionId', 128)
      const win = BrowserWindow.fromWebContents(event.sender)
      if (!win) throw new Error('听写窗口不存在')
      await startDoubaoAsrSession(sessionId, getVoiceDictationSettings(), win)
    },
  )

  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.SEND_AUDIO, (_event, input: VoiceDictationAudioChunkInput): void => {
    sendDoubaoAsrAudio(input.sessionId, input.data)
  })

  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.STOP,
    async (_event, input: VoiceDictationStopInput): Promise<void> => {
      const sessionId = assertString(input?.sessionId, 'sessionId', 128)
      await stopDoubaoAsrSession(sessionId)
    },
  )

  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.CANCEL,
    (_event, input: VoiceDictationStopInput): void => {
      const sessionId = assertString(input?.sessionId, 'sessionId', 128)
      cancelDoubaoAsrSession(sessionId)
    },
  )

  // commit 统一走外部输出（光标粘贴 → 剪贴板回退）。
  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.COMMIT,
    async (_event, input: VoiceDictationCommitInput): Promise<VoiceDictationCommitResult> => {
      const text = assertString(input?.text, 'text', 32_000).trim()
      const sessionId = typeof input?.sessionId === 'string' ? input.sessionId : ''
      if (!text) {
        return { mode: 'clipboard', success: false, message: '没有可输出的语音文本' }
      }

      const settings = getVoiceDictationSettings()
      if (sessionId) cancelDoubaoAsrSession(sessionId)

      if (settings.outputMode === 'clipboard') {
        clipboard.writeText(text)
        addHistoryEntry(text, 'clipboard')
        return { mode: 'clipboard', success: true, message: '已复制到剪贴板' }
      }

      try {
        const result = await pasteTextAtCurrentCursor(text)
        if (result.success) addHistoryEntry(text, 'cursor')
        return {
          mode: 'cursor',
          success: result.success,
          message: result.message,
        }
      } catch (error) {
        clipboard.writeText(text)
        addHistoryEntry(text, 'clipboard')
        const detail = error instanceof Error ? error.message : String(error)
        console.warn('[听写] 光标写入失败，已回退剪贴板:', detail)
        return { mode: 'clipboard', success: true, message: `光标写入失败，已复制到剪贴板（${detail}）` }
      }
    },
  )

  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.HIDE, (): void => {
    finishCaptureSession()
  })

  ipcMain.handle(
    VOICE_DICTATION_IPC_CHANNELS.RESIZE,
    (_event, input: VoiceDictationResizeInput): void => {
      if (typeof input?.height !== 'number' || !Number.isFinite(input.height)) return
      resizeCaptureWindow(input.height)
    },
  )

  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.CHECK_MIC_PERMISSION, async (): Promise<MicPermissionResult> => {
    if (process.platform !== 'darwin') {
      return { status: 'granted', platform: process.platform }
    }
    const status = systemPreferences.getMediaAccessStatus('microphone')
    return {
      status: status === 'granted' || status === 'denied' || status === 'not-determined' ? status : 'unsupported',
      platform: process.platform,
    }
  })

  ipcMain.handle(VOICE_DICTATION_IPC_CHANNELS.REQUEST_MIC_PERMISSION, async (): Promise<MicPermissionResult> => {
    if (process.platform !== 'darwin') {
      return { status: 'granted', platform: process.platform }
    }
    const granted = await systemPreferences.askForMediaAccess('microphone')
    return { status: granted ? 'granted' : 'denied', platform: process.platform }
  })
}

function registerAppHandlers(): void {
  ipcMain.handle(VOICE_APP_IPC_CHANNELS.GET_APP_SETTINGS, () => getVoiceAppSettings())

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.CHECK_HOTKEY, () => {
    const { getVoiceHotkeyStatus } = require('./shortcuts') as typeof import('./shortcuts')
    return getVoiceHotkeyStatus()
  })

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.UPDATE_APP_SETTINGS, (_event, updates: { hotkey?: string; launchAtLogin?: boolean }) => {
    const { updateVoiceHotkey } = require('./shortcuts') as typeof import('./shortcuts')
    const current = getVoiceAppSettings()
    let result = current
    if (typeof updates?.hotkey === 'string') {
      const { settings } = updateVoiceHotkey(updates.hotkey.slice(0, 128))
      result = settings
    }
    if (typeof updates?.launchAtLogin === 'boolean') {
      applyLoginItemSettings({ ...current, launchAtLogin: updates.launchAtLogin })
      const { updateVoiceAppSettings } = require('./settings-store') as typeof import('./settings-store')
      result = updateVoiceAppSettings({ launchAtLogin: updates.launchAtLogin })
    }
    notifySettingsChanged()
    return result
  })

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.CHECK_ACCESSIBILITY, () => {
    if (process.platform !== 'darwin') return { supported: false, enabled: true }
    return { supported: true, enabled: systemPreferences.isTrustedAccessibilityClient(false) }
  })

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.OPEN_ACCESSIBILITY_SETTINGS, () => {
    if (process.platform === 'darwin') {
      // 触发一次辅助功能探活（会向系统注册本应用），再打开系统设置面板。
      systemPreferences.isTrustedAccessibilityClient(true)
      const { shell } = require('electron') as typeof import('electron')
      void shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility')
    }
  })

  // 仅放行 https 外链（设置页跳转火山引擎控制台等）。
  ipcMain.handle(VOICE_APP_IPC_CHANNELS.OPEN_URL, (_event, rawUrl: string) => {
    let parsed: URL
    try {
      parsed = new URL(assertString(rawUrl, 'url', 2048))
    } catch {
      throw new Error('无效的链接')
    }
    if (parsed.protocol !== 'https:') throw new Error('仅允许 https 链接')
    const { shell } = require('electron') as typeof import('electron')
    void shell.openExternal(parsed.toString())
  })

  ipcMain.on(VOICE_APP_IPC_CHANNELS.QUIT, () => {
    const { app } = require('electron') as typeof import('electron')
    app.quit()
  })

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.GET_STATE, () => ({
    captureActive: isCaptureActive(),
  }))

  ipcMain.handle(VOICE_APP_IPC_CHANNELS.GET_HISTORY, () => getHistoryEntries())
  ipcMain.handle(VOICE_APP_IPC_CHANNELS.DELETE_HISTORY_ENTRY, (_event, id: string) => deleteHistoryEntry(assertString(id, 'id', 128)))
  ipcMain.handle(VOICE_APP_IPC_CHANNELS.CLEAR_HISTORY, () => clearHistory())
}

export function registerVoiceIpcHandlers(): void {
  registerVoiceDictationHandlers()
  registerAppHandlers()
  // 错误路径兜底：任何听写异常后 renderer 可请求复位窗口状态机。
  ipcMain.on('voice-app:reset-capture', () => resetCaptureSession())
}

let settingsChangedCallback: (() => void) | null = null

/** 主进程注册“设置已变化”回调（用于刷新托盘状态）。 */
export function registerSettingsChangedCallback(callback: () => void): void {
  settingsChangedCallback = callback
}

function notifySettingsChanged(): void {
  settingsChangedCallback?.()
}
