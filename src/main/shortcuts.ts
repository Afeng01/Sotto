/**
 * 全局快捷键注册
 *
 * 默认 Alt+`，可在设置中自定义录制或禁用。
 * 注册失败（快捷键被其他应用占用）不会阻塞应用，但状态会反馈到设置页与启动提示。
 */

import { globalShortcut } from 'electron'
import { getVoiceAppSettings, updateVoiceAppSettings, type VoiceAppSettings } from './settings-store'
import { toggleCaptureWindow } from './voice-capture-window'

let registeredAccelerator: string | null = null

export interface HotkeyStatus {
  hotkey: string
  registered: boolean
}

export function registerVoiceHotkey(): boolean {
  unregisterVoiceHotkey()
  const { hotkey } = getVoiceAppSettings()
  if (!hotkey) {
    console.log('[快捷键] 用户已禁用全局听写快捷键')
    return false
  }
  try {
    const success = globalShortcut.register(hotkey, toggleCaptureWindow)
    if (success) {
      registeredAccelerator = hotkey
    } else {
      console.warn(`[快捷键] 注册失败（可能被其他应用占用）: ${hotkey}`)
    }
    return success
  } catch (error) {
    console.error('[快捷键] 注册异常:', error)
    return false
  }
}

export function getVoiceHotkeyStatus(): HotkeyStatus {
  const { hotkey } = getVoiceAppSettings()
  return { hotkey, registered: hotkey !== '' && registeredAccelerator === hotkey }
}

export function unregisterVoiceHotkey(): void {
  if (registeredAccelerator) {
    try {
      globalShortcut.unregister(registeredAccelerator)
    } catch (error) {
      console.error('[快捷键] 注销异常:', error)
    }
    registeredAccelerator = null
  }
}

export function updateVoiceHotkey(hotkey: string): { settings: VoiceAppSettings; registered: boolean } {
  const next = updateVoiceAppSettings({ hotkey })
  const registered = registerVoiceHotkey()
  return { settings: next, registered }
}
