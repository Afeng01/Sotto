/**
 * 菜单栏托盘
 *
 * 状态图标 + 菜单（状态 / 设置 / 退出）。菜单可在设置变化后重建。
 */

import { Menu, nativeImage, Tray } from 'electron'

export interface TrayDeps {
  /** 当前托盘图标路径 */
  iconPath: string
  openSettings: () => void
  /** 豆包凭证是否已配置（影响状态文案） */
  isConfigured: () => boolean
  quit: () => void
}

let tray: Tray | null = null

function buildMenu(deps: TrayDeps): Menu {
  return Menu.buildFromTemplate([
    { label: deps.isConfigured() ? '语音输入已就绪' : '尚未配置豆包凭证', enabled: false },
    { type: 'separator' },
    { label: '设置…', click: () => deps.openSettings() },
    { type: 'separator' },
    { label: '退出呦呦', click: () => deps.quit() },
  ])
}

export function createTray(deps: TrayDeps): Tray {
  if (tray && !tray.isDestroyed()) return tray
  const image = nativeImage.createFromPath(deps.iconPath).resize({ width: 18, height: 18 })
  tray = new Tray(image)
  tray.setToolTip('呦呦 Sotto')
  tray.setContextMenu(buildMenu(deps))
  return tray
}

export function refreshTrayMenu(deps: TrayDeps): void {
  if (!tray || tray.isDestroyed()) return
  tray.setContextMenu(buildMenu(deps))
}

export function destroyTray(): void {
  if (tray && !tray.isDestroyed()) tray.destroy()
  tray = null
}
