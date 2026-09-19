/**
 * 听写历史存储
 *
 * 每次成功输出（写入光标或剪贴板）追加一条记录，最多保留 100 条。
 * 存储于 ~/.sotto/history.json，与设置同样采用原子写入。
 */

import { app } from 'electron'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export interface HistoryEntry {
  id: string
  text: string
  /** 'cursor' = 写入光标，'clipboard' = 复制到剪贴板 */
  mode: 'cursor' | 'clipboard'
  createdAt: number
}

const MAX_ENTRIES = 100

function historyFilePath(): string {
  return join(app.getPath('home'), '.sotto', 'history.json')
}

function readEntries(): HistoryEntry[] {
  const filePath = historyFilePath()
  try {
    if (!existsSync(filePath)) return []
    const parsed = JSON.parse(readFileSync(filePath, 'utf-8')) as { entries?: HistoryEntry[] }
    if (!Array.isArray(parsed.entries)) return []
    return parsed.entries.filter((entry) => typeof entry?.id === 'string' && typeof entry?.text === 'string')
  } catch (error) {
    console.warn('[历史] 读取失败，按空处理:', error)
    return []
  }
}

function writeEntries(entries: HistoryEntry[]): void {
  const filePath = historyFilePath()
  const tmpPath = filePath + '.tmp'
  writeFileSync(tmpPath, JSON.stringify({ version: 1, entries }, null, 2), 'utf-8')
  renameSync(tmpPath, filePath)
}

export function addHistoryEntry(text: string, mode: HistoryEntry['mode']): HistoryEntry {
  const entry: HistoryEntry = {
    id: crypto.randomUUID(),
    text: text.slice(0, 4000),
    mode,
    createdAt: Date.now(),
  }
  const entries = [entry, ...readEntries()].slice(0, MAX_ENTRIES)
  try {
    writeEntries(entries)
  } catch (error) {
    console.warn('[历史] 写入失败:', error)
  }
  return entry
}

export function getHistoryEntries(): HistoryEntry[] {
  return readEntries()
}

export function deleteHistoryEntry(id: string): HistoryEntry[] {
  const entries = readEntries().filter((entry) => entry.id !== id)
  try {
    writeEntries(entries)
  } catch (error) {
    console.warn('[历史] 删除失败:', error)
  }
  return entries
}

export function clearHistory(): HistoryEntry[] {
  try {
    writeEntries([])
  } catch (error) {
    console.warn('[历史] 清空失败:', error)
  }
  return []
}
