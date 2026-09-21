/**
 * Sotto（呦呦） 设置存储
 *
 * 独立应用的本地设置文件（~/.sotto/settings.json）。
 * - 豆包 Access Token 使用 safeStorage 加密后落盘，不可用时降级明文
 * - JSON 写入遵循 write-to-temp → rename 原子写 + .bak 备份模式（对齐 safe-file.ts 约定）
 */

import { safeStorage } from 'electron'
import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type {
  VoiceDictationSettings,
  VoiceDictationSettingsUpdate,
  VoiceDictationPersistedSettings,
} from '@sotto/voice'
import { app } from 'electron'

/** 语音识别设置（解密后的运行时形态） */
export type { VoiceDictationSettings, VoiceDictationSettingsUpdate }

/** 应用级设置 */
export interface VoiceAppSettings {
  /** 全局听写快捷键（Electron accelerator 格式） */
  hotkey: string
  /** 开机自启并隐藏启动 */
  launchAtLogin: boolean
}

/** 落盘文件结构 */
interface PersistedFile {
  version: 1
  app?: Partial<VoiceAppSettings>
  voiceDictation?: VoiceDictationPersistedSettings
}

const DEFAULT_VOICE_DICTATION_SETTINGS: VoiceDictationSettings = {
  enabled: true,
  provider: 'doubao',
  appId: '',
  accessToken: '',
  apiKey: '',
  credentialMode: 'api-key',
  resourceId: 'volc.seedasr.sauc.duration',
  language: '',
  endpointMode: 'async',
  outputMode: 'auto',
  customHotwords: '',
}

const DEFAULT_APP_SETTINGS: VoiceAppSettings = {
  hotkey: 'Control+`',
  launchAtLogin: false,
}

let cache: PersistedFile | null = null

function settingsFilePath(): string {
  return join(app.getPath('home'), '.sotto', 'settings.json')
}

/** 原子写 JSON：write-to-temp → rename + .bak 备份(write-to-temp → rename 模式) */
function writeJsonFileAtomic(filePath: string, data: PersistedFile): void {
  const tmpPath = filePath + '.tmp'
  const bakPath = filePath + '.bak'
  mkdirSync(join(filePath, '..'), { recursive: true })
  if (existsSync(filePath)) {
    try {
      copyFileSync(filePath, bakPath)
    } catch {
      // 备份失败不阻塞写入
    }
  }
  writeFileSync(tmpPath, JSON.stringify(data, null, 2), 'utf-8')
  renameSync(tmpPath, filePath)
}

function loadPersisted(): PersistedFile {
  if (cache) return cache
  const filePath = settingsFilePath()
  const candidates = [filePath, filePath + '.bak', filePath + '.tmp']
  for (const candidate of candidates) {
    if (!existsSync(candidate)) continue
    try {
      const parsed = JSON.parse(readFileSync(candidate, 'utf-8')) as PersistedFile
      if (parsed && typeof parsed === 'object') {
        cache = parsed
        return cache
      }
    } catch (error) {
      console.error(`[设置] 读取 ${candidate} 失败:`, error)
    }
  }
  cache = { version: 1 }
  return cache
}

function persist(next: PersistedFile): void {
  cache = next
  try {
    writeJsonFileAtomic(settingsFilePath(), next)
  } catch (error) {
    console.error('[设置] 写入设置文件失败:', error)
  }
}

function encryptSecret(value: string): string {
  if (!value) return ''
  if (!safeStorage.isEncryptionAvailable()) {
    console.warn('[设置] safeStorage 加密不可用，凭证将以明文存储')
    return value
  }
  return safeStorage.encryptString(value).toString('base64')
}

function decryptSecret(value: string): string {
  if (!value) return ''
  if (!safeStorage.isEncryptionAvailable()) return value
  try {
    return safeStorage.decryptString(Buffer.from(value, 'base64'))
  } catch {
    // 兼容从明文迁移过来的值（首次保存后会被加密覆盖）
    return value
  }
}

/** 获取解密后的语音识别设置 */
export function getVoiceDictationSettings(): VoiceDictationSettings {
  const raw = loadPersisted().voiceDictation ?? {}
  const encryptedAccessToken = raw.accessToken ?? raw.accessKey ?? ''
  const credentialMode = raw.credentialMode ?? (raw.apiKey ? 'api-key' : 'legacy')
  return {
    ...DEFAULT_VOICE_DICTATION_SETTINGS,
    ...raw,
    appId: raw.appId ?? raw.appKey ?? '',
    accessToken: decryptSecret(encryptedAccessToken),
    apiKey: decryptSecret(raw.apiKey ?? ''),
    credentialMode: credentialMode === 'legacy' ? 'legacy' : 'api-key',
    customHotwords: typeof raw.customHotwords === 'string' ? raw.customHotwords : '',
    enabled: raw.enabled !== false,
  }
}

/** 保存语音识别设置，Access Token 加密后落盘 */
export function updateVoiceDictationSettings(
  updates: VoiceDictationSettingsUpdate,
): VoiceDictationSettings {
  const current = getVoiceDictationSettings()
  const next: VoiceDictationSettings = {
    ...current,
    ...updates,
    provider: 'doubao',
  }
  const persisted = loadPersisted()
  persist({
    ...persisted,
    voiceDictation: {
      ...next,
      accessToken: encryptSecret(next.accessToken),
      apiKey: encryptSecret(next.apiKey),
    },
  })
  return next
}

/** 获取应用级设置 */
export function getVoiceAppSettings(): VoiceAppSettings {
  const raw = loadPersisted().app ?? {}
  return {
    ...DEFAULT_APP_SETTINGS,
    ...raw,
    hotkey: typeof raw.hotkey === 'string' && raw.hotkey ? raw.hotkey : DEFAULT_APP_SETTINGS.hotkey,
  }
}

/** 保存应用级设置 */
export function updateVoiceAppSettings(updates: Partial<VoiceAppSettings>): VoiceAppSettings {
  const current = getVoiceAppSettings()
  const next: VoiceAppSettings = { ...current, ...updates }
  persist({ ...loadPersisted(), app: next })
  applyLoginItemSettings(next)
  return next
}

/** 应用开机自启（macOS 用 openAsHidden 保持无感启动） */
export function applyLoginItemSettings(settings: VoiceAppSettings): void {
  if (process.platform !== 'darwin' && process.platform !== 'win32') return
  try {
    if (typeof app.setLoginItemSettings !== 'function') return
    app.setLoginItemSettings({
      openAtLogin: settings.launchAtLogin,
      openAsHidden: true,
    })
  } catch (error) {
    console.error('[设置] 设置开机自启失败:', error)
  }
}

/** 供测试注入内存态 */
export function __resetSettingsCacheForTest(): void {
  cache = null
}
