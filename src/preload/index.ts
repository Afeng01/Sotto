/**
 * Sotto（呦呦） preload bridge
 *
 * contextBridge 暴露最小听写 API；通道常量与类型来自 @sotto/voice。
 */

import { contextBridge, ipcRenderer } from 'electron'
import {
  VOICE_APP_IPC,
  VOICE_DICTATION_IPC,
} from './channels'
import type {
  MicPermissionResult,
  VoiceDictationAudioChunkInput,
  VoiceDictationCommitInput,
  VoiceDictationCommitResult,
  VoiceDictationResizeInput,
  VoiceDictationSettings,
  VoiceDictationSettingsUpdate,
  VoiceDictationShownEvent,
  VoiceDictationStartInput,
  VoiceDictationStateEvent,
  VoiceDictationStopInput,
  VoiceDictationTranscriptEvent,
} from '@sotto/voice'

export interface VoiceAppSettingsBridge {
  hotkey: string
  launchAtLogin: boolean
}

const api = {
  // 语音识别设置
  getVoiceDictationSettings: (): Promise<VoiceDictationSettings> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.GET_SETTINGS),
  updateVoiceDictationSettings: (updates: VoiceDictationSettingsUpdate): Promise<VoiceDictationSettings> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.UPDATE_SETTINGS, updates),
  testVoiceDictationConnection: (): Promise<{ success: boolean; message: string }> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.TEST_CONNECTION),

  // ASR 会话
  startVoiceDictation: (input: VoiceDictationStartInput): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.START, input),
  sendVoiceDictationAudio: (input: VoiceDictationAudioChunkInput): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.SEND_AUDIO, input),
  stopVoiceDictation: (input: VoiceDictationStopInput): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.STOP, input),
  cancelVoiceDictation: (input: VoiceDictationStopInput): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.CANCEL, input),
  commitVoiceDictation: (input: VoiceDictationCommitInput): Promise<VoiceDictationCommitResult> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.COMMIT, input),
  hideVoiceDictation: (): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.HIDE),
  resizeVoiceDictation: (input: VoiceDictationResizeInput): Promise<void> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.RESIZE, input),

  // 事件
  onVoiceDictationShown: (callback: (event: VoiceDictationShownEvent) => void): (() => void) => {
    const listener = (_: unknown, event: VoiceDictationShownEvent): void => callback(event)
    ipcRenderer.on(VOICE_DICTATION_IPC.SHOWN, listener)
    return () => { ipcRenderer.removeListener(VOICE_DICTATION_IPC.SHOWN, listener) }
  },
  onVoiceDictationToggleStop: (callback: () => void): (() => void) => {
    const listener = (): void => callback()
    ipcRenderer.on(VOICE_DICTATION_IPC.TOGGLE_STOP, listener)
    return () => { ipcRenderer.removeListener(VOICE_DICTATION_IPC.TOGGLE_STOP, listener) }
  },
  onVoiceDictationTranscript: (callback: (event: VoiceDictationTranscriptEvent) => void): (() => void) => {
    const listener = (_: unknown, event: VoiceDictationTranscriptEvent): void => callback(event)
    ipcRenderer.on(VOICE_DICTATION_IPC.TRANSCRIPT, listener)
    return () => { ipcRenderer.removeListener(VOICE_DICTATION_IPC.TRANSCRIPT, listener) }
  },
  onVoiceDictationState: (callback: (event: VoiceDictationStateEvent) => void): (() => void) => {
    const listener = (_: unknown, event: VoiceDictationStateEvent): void => callback(event)
    ipcRenderer.on(VOICE_DICTATION_IPC.STATE, listener)
    return () => { ipcRenderer.removeListener(VOICE_DICTATION_IPC.STATE, listener) }
  },

  // 权限
  checkMicrophonePermission: (): Promise<MicPermissionResult> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.CHECK_MIC_PERMISSION),
  requestMicrophonePermission: (): Promise<MicPermissionResult> =>
    ipcRenderer.invoke(VOICE_DICTATION_IPC.REQUEST_MIC_PERMISSION),

  // 应用级
  getAppSettings: (): Promise<VoiceAppSettingsBridge> =>
    ipcRenderer.invoke(VOICE_APP_IPC.GET_APP_SETTINGS),
  updateAppSettings: (updates: { hotkey?: string; launchAtLogin?: boolean }): Promise<VoiceAppSettingsBridge> =>
    ipcRenderer.invoke(VOICE_APP_IPC.UPDATE_APP_SETTINGS, updates),
  checkHotkeyStatus: (): Promise<{ hotkey: string; registered: boolean }> =>
    ipcRenderer.invoke(VOICE_APP_IPC.CHECK_HOTKEY),
  getHistory: (): Promise<Array<{ id: string; text: string; mode: 'cursor' | 'clipboard'; createdAt: number }>> =>
    ipcRenderer.invoke(VOICE_APP_IPC.GET_HISTORY),
  deleteHistoryEntry: (id: string): Promise<Array<{ id: string; text: string; mode: 'cursor' | 'clipboard'; createdAt: number }>> =>
    ipcRenderer.invoke(VOICE_APP_IPC.DELETE_HISTORY_ENTRY, id),
  clearHistory: (): Promise<void> =>
    ipcRenderer.invoke(VOICE_APP_IPC.CLEAR_HISTORY),
  checkAccessibility: (): Promise<{ supported: boolean; enabled: boolean }> =>
    ipcRenderer.invoke(VOICE_APP_IPC.CHECK_ACCESSIBILITY),
  openAccessibilitySettings: (): Promise<void> =>
    ipcRenderer.invoke(VOICE_APP_IPC.OPEN_ACCESSIBILITY_SETTINGS),
  openExternal: (url: string): Promise<void> =>
    ipcRenderer.invoke(VOICE_APP_IPC.OPEN_URL, url),
  openSettings: (): void => {
    ipcRenderer.send(VOICE_APP_IPC.OPEN_SETTINGS_WINDOW)
  },
  quit: (): void => {
    ipcRenderer.send(VOICE_APP_IPC.QUIT)
  },
}

contextBridge.exposeInMainWorld('voiceAPI', api)
