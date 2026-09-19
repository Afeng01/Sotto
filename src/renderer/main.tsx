/**
 * Sotto（呦呦） renderer 入口
 *
 * 按 query 参数路由窗口形态：
 * - ?window=voice-capture → 听写采集浮窗
 * - ?window=settings（或缺省）→ 设置窗口
 */

import './index.css'
import * as React from 'react'
import ReactDOM from 'react-dom/client'
import { VoiceCaptureApp } from './VoiceCaptureApp'
import { SettingsApp } from './SettingsApp'

const params = new URLSearchParams(window.location.search)
const windowKind = params.get('window') ?? 'settings'

function Root(): React.ReactElement {
  if (windowKind === 'voice-capture') return <VoiceCaptureApp />
  return <SettingsApp />
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
)
