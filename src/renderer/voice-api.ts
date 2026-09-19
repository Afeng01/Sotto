import type {
  MicPermissionResult,
  VoiceDictationCommitResult,
  VoiceDictationSettings,
  VoiceDictationSettingsUpdate,
  VoiceDictationShownEvent,
  VoiceDictationStateEvent,
  VoiceDictationTranscriptEvent,
} from '@sotto/voice'

/** Sotto preload bridge（window.voiceAPI）的类型声明。 */

export interface VoiceAppSettings {
  hotkey: string
  launchAtLogin: boolean
}

export interface VoiceAPI {
  getVoiceDictationSettings(): Promise<VoiceDictationSettings>
  updateVoiceDictationSettings(updates: VoiceDictationSettingsUpdate): Promise<VoiceDictationSettings>
  testVoiceDictationConnection(): Promise<{ success: boolean; message: string }>

  startVoiceDictation(input: { sessionId: string }): Promise<void>
  sendVoiceDictationAudio(input: { sessionId: string; data: ArrayBuffer }): Promise<void>
  stopVoiceDictation(input: { sessionId: string }): Promise<void>
  cancelVoiceDictation(input: { sessionId: string; previewSessionId?: string; outputContextId?: string }): Promise<void>
  commitVoiceDictation(input: { sessionId: string; text: string; outputContextId?: string }): Promise<VoiceDictationCommitResult>
  hideVoiceDictation(): Promise<void>
  resizeVoiceDictation(input: { height: number }): Promise<void>

  onVoiceDictationShown(callback: (event: VoiceDictationShownEvent) => void): () => void
  onVoiceDictationToggleStop(callback: () => void): () => void
  onVoiceDictationTranscript(callback: (event: VoiceDictationTranscriptEvent) => void): () => void
  onVoiceDictationState(callback: (event: VoiceDictationStateEvent) => void): () => void

  checkMicrophonePermission(): Promise<MicPermissionResult>
  requestMicrophonePermission(): Promise<MicPermissionResult>

  getAppSettings(): Promise<VoiceAppSettings>
  updateAppSettings(updates: { hotkey?: string; launchAtLogin?: boolean }): Promise<VoiceAppSettings>
  checkHotkeyStatus(): Promise<{ hotkey: string; registered: boolean }>
  checkAccessibility(): Promise<{ supported: boolean; enabled: boolean }>
  openAccessibilitySettings(): Promise<void>
  openExternal(url: string): Promise<void>
  openSettings(): void
  quit(): void
}

declare global {
  interface Window {
    voiceAPI: VoiceAPI
    webkitAudioContext?: typeof AudioContext
  }
}

export {}
