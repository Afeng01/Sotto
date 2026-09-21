/**
 * SettingsApp — 呦呦（Sotto）设置窗口
 *
 * 布局：吸顶可拖拽标题栏（避让交通灯）+ 左侧导航多页面结构，
 * 每页内容限宽居中，窗口缩放自适应。设计原则参考 app 型功能页：
 * 导航常驻、视觉克制、信息密度紧凑、可操作元素均有 hover/active。
 */

import * as React from 'react'
import {
  CheckCircle2,
  Copy,
  Eye,
  EyeOff,
  History,
  Info,
  Loader2,
  Mic,
  MicOff,
  ShieldAlert,
  ShieldCheck,
  SlidersHorizontal,
  Trash2,
  XCircle,
} from 'lucide-react'
import type { VoiceDictationSettings } from '@sotto/voice'
import type { HistoryEntry, VoiceAppSettings } from './voice-api'

const VOLCENGINE_SPEECH_SERVICE_URL = 'https://console.volcengine.com/speech/service/'
const APP_VERSION = '0.1.0'

const ENDPOINT_OPTIONS = [
  { value: 'async', label: '双向流式优化版' },
  { value: 'duplex', label: '双向流式标准版' },
]

const LANGUAGE_OPTIONS = [
  { value: 'auto', label: '自动识别' },
  { value: 'zh-CN', label: '中文普通话' },
  { value: 'en-US', label: '英语' },
  { value: 'yue-CN', label: '粤语' },
  { value: 'ja-JP', label: '日语' },
  { value: 'ko-KR', label: '韩语' },
]

const HOTKEY_PRESETS = [
  { value: 'Alt+`', label: 'Alt + `' },
  { value: 'Control+`', label: 'Ctrl + `' },
  { value: 'Alt+V', label: 'Alt + V' },
  { value: 'F5', label: 'F5' },
  { value: '', label: '禁用' },
]

const MODIFIERS = [
  { flag: 'metaKey', part: 'Super', sym: '⌘' },
  { flag: 'ctrlKey', part: 'Control', sym: '⌃' },
  { flag: 'altKey', part: 'Alt', sym: '⌥' },
  { flag: 'shiftKey', part: 'Shift', sym: '⇧' },
] as const

const CODE_KEY_MAP: Record<string, string> = {
  Backquote: '`', Minus: '-', Equal: '=', BracketLeft: '[', BracketRight: ']',
  Semicolon: ';', Quote: "'", Comma: ',', Period: '.', Slash: '/', Backslash: '\\',
}

function eventToAccelerator(event: React.KeyboardEvent): string | null {
  const key = /^[a-zA-Z]$/.test(event.key)
    ? event.key.toUpperCase()
    : /^[0-9]$/.test(event.key) || /^F\d{1,2}$/.test(event.key)
      ? event.key
      : event.code === 'Space'
        ? 'Space'
        : (CODE_KEY_MAP[event.code] ?? null)
  if (!key) return null
  const mods = MODIFIERS.filter((m) => event[m.flag]).map((m) => m.part)
  return [...mods, key].join('+')
}

function prettyAccelerator(accel: string): string {
  if (!accel) return '禁用'
  const sym: Record<string, string> = { Control: '⌃', Alt: '⌥', Shift: '⇧', Super: '⌘' }
  const parts = accel.split('+')
  const key = parts.pop() ?? ''
  return [...parts.map((p) => sym[p] ?? p), key].join(' ')
}

function HotkeyRecorder({
  value,
  recording,
  onRecord,
  onCancel,
  onCapture,
  onClear,
  onInvalid,
}: {
  value: string
  recording: boolean
  onRecord: () => void
  onCancel: () => void
  onCapture: (accelerator: string) => void
  onClear: () => void
  onInvalid: (message: string) => void
}): React.ReactElement {
  const handleKeyDown = (event: React.KeyboardEvent): void => {
    event.preventDefault()
    event.stopPropagation()
    if (event.key === 'Escape') {
      onCancel()
      return
    }
    if (event.key === 'Delete' || event.key === 'Backspace') {
      onClear()
      return
    }
    const accelerator = eventToAccelerator(event)
    if (!accelerator) return
    const hasModifier = MODIFIERS.some((m) => event[m.flag])
    const isFKey = /^F\d{1,2}$/.test(accelerator)
    if (!hasModifier && !isFKey) {
      onInvalid('需要包含 Ctrl / Alt / Cmd / Shift，或直接使用 F 功能键')
      return
    }
    onCapture(accelerator)
  }

  if (recording) {
    return (
      <div
        tabIndex={0}
        autoFocus
        onKeyDown={handleKeyDown}
        onBlur={onCancel}
        className="flex min-w-[180px] items-center justify-center rounded-md border border-primary bg-primary/5 px-3 py-1.5 text-xs text-primary outline-none ring-2 ring-ring/30"
      >
        按下组合键…（Esc 取消）
      </div>
    )
  }

  return (
    <button
      type="button"
      onClick={onRecord}
      title={value ? '点击录制新快捷键' : '当前已禁用，点击录制'}
      className="min-w-[180px] rounded-md border border-border bg-transparent px-3 py-1.5 text-left text-xs transition-colors hover:border-ring hover:bg-muted/50"
    >
      {value ? (
        <span className="font-mono text-[13px] text-foreground">{prettyAccelerator(value)}</span>
      ) : (
        <span className="text-muted-foreground">点击录制</span>
      )}
    </button>
  )
}

type PageId = 'voice' | 'history' | 'general' | 'permissions' | 'about'

const PAGES: Array<{ id: PageId; label: string; icon: typeof Mic }> = [
  { id: 'voice', label: '语音输入', icon: Mic },
  { id: 'history', label: '听写历史', icon: History },
  { id: 'general', label: '通用', icon: SlidersHorizontal },
  { id: 'permissions', label: '系统权限', icon: ShieldCheck },
  { id: 'about', label: '关于', icon: Info },
]

const inputClass =
  'w-full rounded-md border border-border bg-transparent px-3 py-1.5 text-sm outline-none transition-shadow hover:border-border focus:border-ring focus:ring-2 focus:ring-ring/30'
const selectClass =
  'max-w-[200px] rounded-md border border-border bg-transparent px-2 py-1 text-xs outline-none transition-colors hover:border-border focus:ring-2 focus:ring-ring/30'

function Section({ title, children }: { title: string; children: React.ReactNode }): React.ReactElement {
  return (
    <section>
      <h2 className="mb-3 text-xs font-semibold uppercase tracking-wider text-muted-foreground">{title}</h2>
      <div className="space-y-4">{children}</div>
    </section>
  )
}

function Hint({ children }: { children: React.ReactNode }): React.ReactElement {
  return <span className="mb-1.5 block text-xs leading-4 text-muted-foreground">{children}</span>
}

function InlineField({ label, hint, control }: { label: string; hint?: string; control: React.ReactNode }): React.ReactElement {
  return (
    <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
      <div className="min-w-0 flex-1 basis-40">
        <span className="block text-sm text-foreground">{label}</span>
        {hint && <span className="mt-0.5 block text-xs leading-4 text-muted-foreground">{hint}</span>}
      </div>
      <div className="shrink-0">{control}</div>
    </div>
  )
}

function formatHistoryTime(timestamp: number): string {
  const date = new Date(timestamp)
  const now = new Date()
  const sameDay = date.toDateString() === now.toDateString()
  const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
  if (sameDay) return `今天 ${time}`
  return `${date.getMonth() + 1}月${date.getDate()}日 ${time}`
}

function Toggle({ checked, onChange }: { checked: boolean; onChange: () => void }): React.ReactElement {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={onChange}
      className={`relative h-5 w-9 rounded-full transition-colors ${checked ? 'bg-primary' : 'bg-border'}`}
    >
      <span className={`absolute top-0.5 size-4 rounded-full bg-white shadow transition-all ${checked ? 'left-[18px]' : 'left-0.5'}`} />
    </button>
  )
}

export function SettingsApp(): React.ReactElement {
  const [page, setPage] = React.useState<PageId>('voice')
  const [settings, setSettings] = React.useState<VoiceDictationSettings | null>(null)
  const [appSettings, setAppSettings] = React.useState<VoiceAppSettings | null>(null)
  const [saveState, setSaveState] = React.useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [saveMessage, setSaveMessage] = React.useState('')
  const [testing, setTesting] = React.useState(false)
  const [testResult, setTestResult] = React.useState<{ success: boolean; message: string } | null>(null)
  const [showSecret, setShowSecret] = React.useState(false)
  const [micPermission, setMicPermission] = React.useState<Awaited<ReturnType<typeof window.voiceAPI.checkMicrophonePermission>> | null>(null)
  const [requestingMic, setRequestingMic] = React.useState(false)
  const [accessibility, setAccessibility] = React.useState<{ supported: boolean; enabled: boolean } | null>(null)
  const [hotkeyStatus, setHotkeyStatus] = React.useState<{ hotkey: string; registered: boolean } | null>(null)
  const [recordingHotkey, setRecordingHotkey] = React.useState(false)
  const [hotkeyError, setHotkeyError] = React.useState<string | null>(null)
  const [history, setHistory] = React.useState<HistoryEntry[] | null>(null)
  const [copiedId, setCopiedId] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (page !== 'history') return
    window.voiceAPI.getHistory().then(setHistory).catch(console.error)
  }, [page])

  React.useEffect(() => {
    void Promise.all([
      window.voiceAPI.getVoiceDictationSettings(),
      window.voiceAPI.getAppSettings(),
      window.voiceAPI.checkAccessibility(),
      window.voiceAPI.checkMicrophonePermission(),
      window.voiceAPI.checkHotkeyStatus(),
    ]).then(([voice, appConfig, a11y, mic, hotkey]) => {
      setSettings(voice)
      setAppSettings(appConfig)
      setAccessibility(a11y)
      setMicPermission(mic)
      setHotkeyStatus(hotkey)
    }).catch(console.error)
  }, [])

  const saveVoice = React.useCallback(async (updates: Partial<VoiceDictationSettings>) => {
    if (!settings) return
    setSaveState('saving')
    try {
      const next = await window.voiceAPI.updateVoiceDictationSettings(updates)
      setSettings(next)
      setSaveState('saved')
      setSaveMessage('已保存')
      setTimeout(() => setSaveState('idle'), 1500)
    } catch (error) {
      setSaveState('error')
      setSaveMessage(error instanceof Error ? error.message : '保存失败')
    }
  }, [settings])

  const saveApp = React.useCallback(async (updates: { hotkey?: string; launchAtLogin?: boolean }) => {
    try {
      const next = await window.voiceAPI.updateAppSettings(updates)
      setAppSettings(next)
      if (typeof updates.hotkey === 'string') {
        setHotkeyStatus(await window.voiceAPI.checkHotkeyStatus())
      }
    } catch (error) {
      console.error('[设置] 保存应用设置失败:', error)
    }
  }, [])

  const handleTest = React.useCallback(async () => {
    setTesting(true)
    setTestResult(null)
    try {
      const result = await window.voiceAPI.testVoiceDictationConnection()
      setTestResult(result)
    } finally {
      setTesting(false)
    }
  }, [])

  const handleRequestMic = React.useCallback(async () => {
    setRequestingMic(true)
    try {
      const result = await window.voiceAPI.requestMicrophonePermission()
      setMicPermission(result)
    } finally {
      setRequestingMic(false)
    }
  }, [])

  if (!settings || !appSettings) {
    return (
      <div className="flex h-screen items-center justify-center bg-background text-sm text-muted-foreground">
        <Loader2 className="mr-2 size-4 animate-spin" /> 加载设置中...
      </div>
    )
  }

  const credentialsReady = Boolean(settings.apiKey || (settings.appId && settings.accessToken))
  const currentPage = PAGES.find((p) => p.id === page)!

  const saveIndicator = saveState === 'saving'
    ? '保存中…'
    : saveState === 'saved'
      ? saveMessage
      : saveState === 'error'
        ? <span className="text-destructive">{saveMessage}</span>
        : null

  return (
    <div className="flex h-screen flex-col bg-background text-sm text-foreground">
      {/* 吸顶标题栏：可拖拽移动窗口，左侧避开交通灯 */}
      <header
        className="flex h-12 shrink-0 items-center border-b border-border/60 bg-background/85 pl-[84px] pr-6 backdrop-blur"
        style={{ WebkitAppRegion: 'drag' } as React.CSSProperties}
      >
        <h1 className="text-sm font-semibold">{currentPage.label}</h1>
        <span className="ml-3 text-xs text-muted-foreground">{saveIndicator}</span>
      </header>

      <div className="flex min-h-0 flex-1">
        {/* 左侧导航 */}
        <nav className="flex w-44 shrink-0 flex-col gap-0.5 border-r border-border/60 px-2.5 py-3">
          {PAGES.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              onClick={() => setPage(id)}
              className={`flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-[13px] transition-colors ${
                page === id
                  ? 'bg-primary/10 font-medium text-primary'
                  : 'text-muted-foreground hover:bg-muted hover:text-foreground'
              }`}
            >
              <Icon className="size-4 shrink-0" />
              {label}
            </button>
          ))}
        </nav>

        {/* 内容区 */}
        <main className="min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto w-full max-w-[520px] px-7 pb-10 pt-6">
            {page === 'voice' && (
              <>
                {/* 引导 */}
                <div className="mb-6 rounded-lg border border-primary/15 bg-primary/5 px-4 py-3.5 text-xs leading-5 text-muted-foreground">
                  <div className="mb-1.5 flex items-center gap-1.5 font-medium text-foreground">
                    <Mic className="size-3.5 text-primary" />
                    自配豆包凭证
                  </div>
                  <p>
                    打开
                    <button
                      type="button"
                      onClick={() => void window.voiceAPI.openExternal(VOLCENGINE_SPEECH_SERVICE_URL)}
                      className="mx-1 text-primary underline underline-offset-4 hover:opacity-80"
                    >
                      火山引擎语音服务控制台
                    </button>
                    ，选择旧版服务界面。
                  </p>
                  <p>找到“豆包流式语音识别模型 2.0”类目，选择已申请对应权限的应用。</p>
                  <p>推荐填写新版控制台的 API Key（只需这一项），再填 Resource ID，然后点击“测试连接”。</p>
                </div>

                <Section title="豆包流式语音输入">
                  <InlineField
                    label="启用语音输入"
                    hint="启用后才能通过快捷键唤起听写浮窗，再按一次停止并输出。"
                    control={<Toggle checked={settings.enabled} onChange={() => void saveVoice({ enabled: !settings.enabled })} />}
                  />

                  <label className="block">
                    <Hint>API Key — 新版控制台推荐方式，对应 X-Api-Key 请求头，只需这一个即可；保存时会加密。</Hint>
                    <div className="relative">
                      <input
                        type={showSecret ? 'text' : 'password'}
                        value={settings.apiKey}
                        onChange={(event) => setSettings({ ...settings, apiKey: event.target.value })}
                        onBlur={(event) => void saveVoice({ apiKey: event.target.value.trim() })}
                        placeholder="请输入新版控制台 API Key"
                        className={`${inputClass} pr-9`}
                      />
                      <button
                        type="button"
                        onClick={() => setShowSecret((v) => !v)}
                        className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                        aria-label={showSecret ? '隐藏' : '显示'}
                      >
                        {showSecret ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                      </button>
                    </div>
                  </label>

                  <div className="rounded-lg border border-dashed border-border/70 p-3">
                    <p className="mb-2 text-xs text-muted-foreground">旧版控制台凭证（二选一，已填 API Key 可忽略）</p>
                    <label className="block">
                    <Hint>豆包 APP ID — 对应 X-Api-App-Key，请填写旧版火山引擎控制台中的 APP ID。</Hint>
                    <input
                      type="text"
                      value={settings.appId}
                      onChange={(event) => setSettings({ ...settings, appId: event.target.value })}
                      onBlur={(event) => void saveVoice({ appId: event.target.value.trim() })}
                      placeholder="请输入 APP ID"
                      className={inputClass}
                    />
                  </label>

                  <label className="block">
                    <Hint>豆包 Access Token — 对应 X-Api-Access-Key，保存时会加密。</Hint>
                    <div className="relative">
                      <input
                        type={showSecret ? 'text' : 'password'}
                        value={settings.accessToken}
                        onChange={(event) => setSettings({ ...settings, accessToken: event.target.value })}
                        onBlur={(event) => void saveVoice({ accessToken: event.target.value.trim() })}
                        placeholder="请输入 Access Token"
                        className={`${inputClass} pr-9`}
                      />
                      <button
                        type="button"
                        onClick={() => setShowSecret((v) => !v)}
                        className="absolute right-2 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                        aria-label={showSecret ? '隐藏' : '显示'}
                      >
                        {showSecret ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                      </button>
                    </div>
                  </label>
                  </div>

                  <label className="block">
                    <Hint>Resource ID — 小时版填 volc.seedasr.sauc.duration，并发版填 volc.seedasr.sauc.concurrent。</Hint>
                    <input
                      type="text"
                      value={settings.resourceId}
                      onChange={(event) => setSettings({ ...settings, resourceId: event.target.value })}
                      onBlur={(event) => void saveVoice({ resourceId: event.target.value.trim() })}
                      placeholder="volc.seedasr.sauc.duration"
                      className={inputClass}
                    />
                  </label>

                  <InlineField
                    label="连接模式"
                    hint="优化版只在结果变化时返回新包，实时体验更好。"
                    control={
                      <select
                        value={settings.endpointMode}
                        onChange={(event) => void saveVoice({ endpointMode: event.target.value as VoiceDictationSettings['endpointMode'] })}
                        className={selectClass}
                      >
                        {ENDPOINT_OPTIONS.map((option) => (
                          <option key={option.value} value={option.value}>{option.label}</option>
                        ))}
                      </select>
                    }
                  />

                  <InlineField
                    label="识别语言"
                    hint="自动识别适合中英文和方言混合输入。"
                    control={
                      <select
                        value={settings.language || 'auto'}
                        onChange={(event) => void saveVoice({ language: event.target.value === 'auto' ? '' : event.target.value })}
                        className={selectClass}
                      >
                        {LANGUAGE_OPTIONS.map((option) => (
                          <option key={option.value} value={option.value}>{option.label}</option>
                        ))}
                      </select>
                    }
                  />

                  <label className="block">
                    <Hint>自定义热词 — 每行或逗号分隔一个词，直传给豆包，用于改善产品名、技术词和人名识别。</Hint>
                    <textarea
                      value={settings.customHotwords}
                      onChange={(event) => setSettings({ ...settings, customHotwords: event.target.value })}
                      onBlur={(event) => void saveVoice({ customHotwords: event.target.value })}
                      placeholder={'呦呦\nClaude Code\n逐字稿'}
                      rows={3}
                      className={`${inputClass} resize-none font-mono text-xs`}
                    />
                  </label>

                  <div className="flex items-center gap-2.5 pt-1">
                    <button
                      type="button"
                      onClick={handleTest}
                      disabled={testing || !credentialsReady}
                      className="rounded-md bg-primary px-3.5 py-1.5 text-xs font-medium text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
                    >
                      {testing ? '测试中...' : '测试连接'}
                    </button>
                    {testResult && (
                      <div className={`flex min-w-0 flex-1 items-start gap-1.5 text-xs leading-4 ${testResult.success ? 'text-muted-foreground' : 'text-destructive'}`}>
                        {testResult.success ? <CheckCircle2 className="mt-0.5 size-3.5 shrink-0" /> : <XCircle className="mt-0.5 size-3.5 shrink-0" />}
                        <span className="min-w-0">{testResult.message}</span>
                      </div>
                    )}
                  </div>
                </Section>
              </>
            )}

            {page === 'history' && (
              <>
                <div className="mb-4 flex items-center justify-between">
                  <span className="text-xs text-muted-foreground">最近 100 条成功输出的听写记录，仅保存在本机。</span>
                  {history && history.length > 0 && (
                    <button
                      type="button"
                      onClick={() => {
                        void window.voiceAPI.clearHistory().then(() => setHistory([]))
                      }}
                      className="rounded-md border border-border px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-destructive"
                    >
                      清空历史
                    </button>
                  )}
                </div>
                {history === null ? (
                  <div className="flex items-center justify-center py-16 text-muted-foreground">
                    <Loader2 className="mr-2 size-4 animate-spin" /> 加载中...
                  </div>
                ) : history.length === 0 ? (
                  <div className="rounded-lg border border-dashed border-border py-16 text-center text-sm text-muted-foreground">
                    还没有听写记录
                    <p className="mt-1.5 text-xs text-muted-foreground/70">按全局快捷键说一段话，成功输出的内容会出现在这里</p>
                  </div>
                ) : (
                  <div className="space-y-2">
                    {history.map((entry) => (
                      <div
                        key={entry.id}
                        className="group rounded-lg border border-border px-3.5 py-2.5 transition-colors hover:border-ring/50"
                      >
                        <div className="flex items-start justify-between gap-3">
                          <p className="min-w-0 flex-1 whitespace-pre-wrap break-words text-sm leading-5 text-foreground [display:-webkit-box] [-webkit-line-clamp:3] [-webkit-box-orient:vertical]">
                            {entry.text}
                          </p>
                          <div className="flex shrink-0 items-center gap-1">
                            <button
                              type="button"
                              aria-label="复制"
                              onClick={() => {
                                void navigator.clipboard.writeText(entry.text).then(() => {
                                  setCopiedId(entry.id)
                                  setTimeout(() => setCopiedId((current) => (current === entry.id ? null : current)), 1200)
                                })
                              }}
                              className="flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                            >
                              {copiedId === entry.id ? <CheckCircle2 className="size-3.5 text-green-500" /> : <Copy className="size-3.5" />}
                            </button>
                            <button
                              type="button"
                              aria-label="删除"
                              onClick={() => {
                                void window.voiceAPI.deleteHistoryEntry(entry.id).then(setHistory)
                              }}
                              className="flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-destructive"
                            >
                              <Trash2 className="size-3.5" />
                            </button>
                          </div>
                        </div>
                        <div className="mt-1.5 flex items-center gap-2 text-[11px] text-muted-foreground/70">
                          <span>{formatHistoryTime(entry.createdAt)}</span>
                          <span>·</span>
                          <span>{entry.mode === 'cursor' ? '写入光标' : '剪贴板'}</span>
                        </div>
                      </div>
                    ))}
                  </div>
                )}
              </>
            )}

            {page === 'general' && (
              <>
                <Section title="听写行为">
                  <div>
                    <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                      <div className="min-w-0 flex-1 basis-40">
                        <span className="block text-sm text-foreground">全局快捷键</span>
                        <span className="mt-0.5 block text-xs leading-4 text-muted-foreground">
                          点击右侧开始录制，按下想要的组合键即可。
                        </span>
                        {hotkeyError && <span className="mt-1 block text-xs text-destructive">{hotkeyError}</span>}
                        {appSettings.hotkey && hotkeyStatus && !hotkeyStatus.registered && (
                          <span className="mt-1 block text-xs text-destructive">
                            注册失败：可能被其他应用占用（例如 Proma 占用 Ctrl + `），请更换。
                          </span>
                        )}
                      </div>
                      <HotkeyRecorder
                        value={appSettings.hotkey}
                        recording={recordingHotkey}
                        onRecord={() => {
                          setHotkeyError(null)
                          setRecordingHotkey(true)
                        }}
                        onCancel={() => setRecordingHotkey(false)}
                        onCapture={(accelerator) => {
                          setRecordingHotkey(false)
                          setHotkeyError(null)
                          void saveApp({ hotkey: accelerator })
                        }}
                        onClear={() => {
                          setRecordingHotkey(false)
                          setHotkeyError(null)
                          void saveApp({ hotkey: '' })
                        }}
                        onInvalid={(message) => setHotkeyError(message)}
                      />
                    </div>
                    <div className="mt-2 flex flex-wrap items-center gap-1.5">
                      {HOTKEY_PRESETS.map((preset) => (
                        <button
                          key={preset.label}
                          type="button"
                          onClick={() => void saveApp({ hotkey: preset.value })}
                          className={`rounded-full border px-2.5 py-0.5 text-[11px] transition-colors ${
                            appSettings.hotkey === preset.value
                              ? 'border-primary/40 bg-primary/10 text-primary'
                              : 'border-border text-muted-foreground hover:bg-muted hover:text-foreground'
                          }`}
                        >
                          {preset.label}
                        </button>
                      ))}
                    </div>
                  </div>

                  <InlineField
                    label="输出方式"
                    hint="写入光标失败时自动保留到剪贴板。"
                    control={
                      <select
                        value={settings.outputMode === 'clipboard' ? 'clipboard' : 'auto'}
                        onChange={(event) => void saveVoice({ outputMode: event.target.value as VoiceDictationSettings['outputMode'] })}
                        className={selectClass}
                      >
                        <option value="auto">自动：写入当前光标</option>
                        <option value="clipboard">仅复制到剪贴板</option>
                      </select>
                    }
                  />
                </Section>

                <div className="my-6 h-px bg-border/70" />

                <Section title="启动">
                  <InlineField
                    label="开机自启"
                    hint="登录时隐藏启动，菜单栏可直接使用。"
                    control={
                      <Toggle
                        checked={appSettings.launchAtLogin}
                        onChange={() => void saveApp({ launchAtLogin: !appSettings.launchAtLogin })}
                      />
                    }
                  />
                </Section>
              </>
            )}

            {page === 'permissions' && (
              <Section title="系统权限">
                <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 rounded-lg border border-border px-3.5 py-2.5">
                  <span className="flex min-w-0 items-center gap-2 text-sm">
                    {micPermission?.status === 'granted' ? (
                      <Mic className="size-4 shrink-0 text-green-500" />
                    ) : micPermission?.status === 'denied' ? (
                      <MicOff className="size-4 shrink-0 text-destructive" />
                    ) : (
                      <Mic className="size-4 shrink-0 text-muted-foreground" />
                    )}
                    麦克风
                  </span>
                  {micPermission?.status === 'granted' ? (
                    <span className="text-xs text-muted-foreground">已授权，语音输入可正常使用</span>
                  ) : micPermission?.status === 'denied' ? (
                    <span className="text-xs text-destructive">已被阻止，请在系统设置中允许</span>
                  ) : (
                    <button
                      type="button"
                      onClick={() => void handleRequestMic()}
                      disabled={requestingMic}
                      className="rounded-md border border-border px-2.5 py-1 text-xs transition-colors hover:bg-muted disabled:opacity-50"
                    >
                      {requestingMic ? '请求中...' : '允许麦克风权限'}
                    </button>
                  )}
                </div>

                {accessibility?.supported && (
                  <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 rounded-lg border border-border px-3.5 py-2.5">
                    <span className="flex items-center gap-2 text-sm">
                      辅助功能
                      {!accessibility.enabled && <ShieldAlert className="size-3.5 text-destructive" />}
                      <span className="text-xs text-muted-foreground">用于把文本写入当前光标位置</span>
                    </span>
                    {accessibility.enabled ? (
                      <span className="text-xs text-muted-foreground">已授权</span>
                    ) : (
                      <button
                        type="button"
                        onClick={() => void window.voiceAPI.openAccessibilitySettings()}
                        className="rounded-md border border-border px-2.5 py-1 text-xs transition-colors hover:bg-muted"
                      >
                        去授权
                      </button>
                    )}
                  </div>
                )}
              </Section>
            )}

            {page === 'about' && (
              <div className="flex flex-col items-center pt-8 text-center">
                <div className="flex size-16 items-center justify-center rounded-2xl bg-primary/10">
                  <Mic className="size-8 text-primary" />
                </div>
                <h2 className="mt-4 text-lg font-semibold">呦呦 Sotto</h2>
                <p className="mt-1 text-xs text-muted-foreground">版本 {APP_VERSION}</p>
                <p className="mt-5 max-w-[360px] text-xs leading-5 text-muted-foreground">
                  独立常驻的系统级语音输入应用。名字取自《诗经·小雅》「呦呦鹿鸣」——鹿鸣声即声音，按下快捷键，呦呦便开始听。
                </p>
                <button
                  type="button"
                  onClick={() => window.voiceAPI.quit()}
                  className="mt-8 rounded-md border border-border px-3.5 py-1.5 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
                >
                  退出呦呦
                </button>
              </div>
            )}
          </div>
        </main>
      </div>
    </div>
  )
}
