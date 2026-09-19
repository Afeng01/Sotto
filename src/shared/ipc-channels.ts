/** Sotto（呦呦） 应用级 IPC 通道常量（主进程与 preload 共用）。 */

export const VOICE_APP_IPC_CHANNELS = {
  GET_APP_SETTINGS: 'voice-app:get-settings',
  UPDATE_APP_SETTINGS: 'voice-app:update-settings',
  CHECK_HOTKEY: 'voice-app:check-hotkey',
  CHECK_ACCESSIBILITY: 'voice-app:check-accessibility',
  OPEN_ACCESSIBILITY_SETTINGS: 'voice-app:open-accessibility-settings',
  OPEN_URL: 'voice-app:open-url',
  OPEN_SETTINGS_WINDOW: 'voice-app:open-settings-window',
  QUIT: 'voice-app:quit',
  GET_STATE: 'voice-app:get-state',
} as const
