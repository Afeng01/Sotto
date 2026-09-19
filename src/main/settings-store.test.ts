/**
 * settings-store 单元测试
 *
 * Electron（safeStorage / app）使用 mock 实现：
 * - safeStorage 用可逆的 base64 编码模拟加解密
 * - app.getPath('home') 指向临时目录
 */

import { describe, test, expect, mock } from 'bun:test'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const homeDir = mkdtempSync(join(tmpdir(), 'sotto-test-'))

mock.module('electron', () => ({
  app: {
    getPath: (_name: string) => homeDir,
  },
  safeStorage: {
    isEncryptionAvailable: () => true,
    encryptString: (value: string) => Buffer.from(`enc:${value}`, 'utf-8'),
    decryptString: (buffer: Buffer) => {
      const text = buffer.toString('utf-8')
      if (!text.startsWith('enc:')) throw new Error('not encrypted')
      return text.slice(4)
    },
  },
}))

const { getVoiceDictationSettings, updateVoiceDictationSettings, getVoiceAppSettings, updateVoiceAppSettings, __resetSettingsCacheForTest } = await import('./settings-store')

describe('Given 空设置目录 When 读取语音设置 Then 返回默认值', () => {
  test('默认 enabled=true 且凭证为空', () => {
    __resetSettingsCacheForTest()
    const settings = getVoiceDictationSettings()
    expect(settings.enabled).toBe(true)
    expect(settings.appId).toBe('')
    expect(settings.accessToken).toBe('')
    expect(settings.resourceId).toBe('volc.seedasr.sauc.duration')
    expect(settings.endpointMode).toBe('async')
    expect(settings.outputMode).toBe('auto')
  })
})

describe('Given 更新语音设置 When 写入并读取 Then Access Token 加密落盘且读取时解密', () => {
  test('round-trip 加密存储', () => {
    __resetSettingsCacheForTest()
    updateVoiceDictationSettings({
      appId: 'test-app-id',
      accessToken: 'secret-token',
    })

    // 磁盘上不能出现明文 token
    const raw = JSON.parse(readFileSync(join(homeDir, '.sotto', 'settings.json'), 'utf-8'))
    expect(raw.voiceDictation.accessToken).not.toBe('secret-token')
    expect(Buffer.from(raw.voiceDictation.accessToken, 'base64').toString('utf-8')).toBe('enc:secret-token')

    const settings = getVoiceDictationSettings()
    expect(settings.appId).toBe('test-app-id')
    expect(settings.accessToken).toBe('secret-token')
  })
})

describe('Given 应用级设置 When 更新快捷键 Then 持久化并回读', () => {
  test('hotkey 更新', () => {
    __resetSettingsCacheForTest()
    expect(getVoiceAppSettings().hotkey).toBe('Control+`')
    const next = updateVoiceAppSettings({ hotkey: 'Alt+V' })
    expect(next.hotkey).toBe('Alt+V')
    __resetSettingsCacheForTest()
    expect(getVoiceAppSettings().hotkey).toBe('Alt+V')
  })
})
