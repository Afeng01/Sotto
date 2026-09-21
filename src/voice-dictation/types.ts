/**
 * 语音输入共享类型与 IPC 通道常量。
 *
 * 语音听写共享类型定义
 * （apps/voice）共同引用，避免两份实现漂移。
 */

/** 语音输入供应商 */
export type VoiceDictationProvider = 'doubao'

/** 豆包 ASR 连接模式 */
export type VoiceDictationEndpointMode = 'async' | 'duplex'

/** 语音输入输出方式 */
export type VoiceDictationOutputMode = 'auto' | 'clipboard'

/** 语音输入浮窗位置 */
export interface VoiceDictationWindowPosition {
  x: number
  y: number
  /** 窗口相对于所在屏幕 workArea 的归一化水平偏移 (0~1) */
  relativeX?: number
  /** 窗口相对于所在屏幕 workArea 的归一化垂直偏移 (0~1) */
  relativeY?: number
}

/** 语音输入设置（渲染进程读取到的是解密后的值） */
export interface VoiceDictationSettings {
  /** 是否启用语音输入 */
  enabled: boolean
  /** 语音识别供应商 */
  provider: VoiceDictationProvider
  /** 豆包 APP ID，对应 X-Api-App-Key 请求头（旧版控制台鉴权） */
  appId: string
  /** 豆包 Access Token，对应 X-Api-Access-Key 请求头（旧版控制台鉴权） */
  accessToken: string
  /** 新版控制台 API Key，对应 X-Api-Key 请求头；凭证方式为 api-key 时使用 */
  apiKey: string
  /** 凭证方式：api-key = 新版控制台（推荐），legacy = 旧版控制台 APP ID + Access Token */
  credentialMode: 'api-key' | 'legacy'
  /** 豆包 Resource ID */
  resourceId: string
  /** 语言，空字符串表示自动 */
  language: string
  /** WebSocket 端点模式 */
  endpointMode: VoiceDictationEndpointMode
  /** 输出方式 */
  outputMode: VoiceDictationOutputMode
  /** 自定义热词，按行或逗号分隔，启动识别时直传给豆包 ASR */
  customHotwords: string
  /** 语音输入浮窗上次拖动后的位置 */
  windowPosition?: VoiceDictationWindowPosition
}

/** 语音输入设置更新 */
export type VoiceDictationSettingsUpdate = Partial<VoiceDictationSettings>

/** 落盘配置，保留旧字段用于从 MVP 早期版本平滑迁移 */
export interface VoiceDictationPersistedSettings extends Partial<VoiceDictationSettings> {
  /** @deprecated 使用 appId */
  appKey?: string
  /** @deprecated 使用 accessToken */
  accessKey?: string
}

/** 语音输入转写事件 */
export interface VoiceDictationTranscriptEvent {
  sessionId: string
  text: string
  isFinal: boolean
}

/** 语音输入状态事件 */
export interface VoiceDictationStateEvent {
  sessionId?: string
  status: 'idle' | 'connecting' | 'recording' | 'stopping' | 'completed' | 'error'
  message?: string
}

/** 渲染进程请求切换听写时携带的来源输入框。 */
export interface VoiceDictationToggleInput {
  sourceInputId?: string
}

/** 主进程冻结的一次听写输出上下文。 */
export interface VoiceDictationOutputContext {
  /** 本次听写是否写入 内部输入框。 */
  externalOutput: boolean
  /** 会话开始时选择的输出模式。 */
  outputMode: VoiceDictationOutputMode
}

/** 主进程确认开始听写时的事件载荷。 */
export interface VoiceDictationShownEvent {
  externalOutput: boolean
  /** 主进程生成的冻结输出上下文 ID，后续 preview / commit / cancel 必须原样带回。 */
  outputContextId: string
  sourceInputId?: string
}

/** 外部应用听写状态条的实时显示数据。 */
export interface VoiceDictationIndicatorEvent {
  state: 'preparing' | 'recording' | 'stopping'
  /** 已归一化、平滑处理后的麦克风音量（0~1）。 */
  volume: number
  /** 尚未提交给第三方应用的实时转写文本。 */
  transcript: string
}

/** 开始语音输入会话参数 */
export interface VoiceDictationStartInput {
  sessionId: string
}

/** 语音音频分片 */
export interface VoiceDictationAudioChunkInput {
  sessionId: string
  data: ArrayBuffer
}

/** 将当前识别结果作为 输入框中的临时组合文本预览。 */
export interface VoiceDictationPreviewInput {
  sessionId: string
  text: string
  /** 本次听写会话冻结的 输出目标；null 表示不路由到内部输入框。 */
  targetInputId?: string | null
  /** 主进程生成的冻结输出上下文 ID。 */
  outputContextId?: string
}

/** 结束语音输入会话参数 */
export interface VoiceDictationStopInput {
  /** 当前 ASR WebSocket 会话 ID */
  sessionId: string
  /** 跨 ASR 重连保持稳定的听写会话 ID */
  previewSessionId?: string
  /** 取消预览时应清理的 输出目标。 */
  targetInputId?: string | null
  /** 主进程生成的冻结输出上下文 ID。 */
  outputContextId?: string
}

/** 输出语音输入文本参数 */
export interface VoiceDictationCommitInput {
  sessionId: string
  text: string
  /** 本次听写会话冻结的 输出目标；null 表示不路由到内部输入框。 */
  targetInputId?: string | null
  /** 主进程生成的冻结输出上下文 ID。 */
  outputContextId?: string
}

/** 主窗口接收的语音组合文本事件。 */
export interface VoiceDictationTextEvent {
  sessionId: string
  text: string
  /** 本次听写会话冻结的 输出目标；null 表示交给全局 fallback 处理。 */
  targetInputId?: string | null
}

/** 渲染进程确认最终听写文本是否被目标输入框消费。 */
export interface VoiceDictationTextDeliveryInput {
  sessionId: string
  delivered: boolean
}

/** 调整语音输入浮窗尺寸参数 */
export interface VoiceDictationResizeInput {
  height: number
}

/** 输出语音输入文本结果 */
export interface VoiceDictationCommitResult {
  mode: 'cursor' | 'clipboard'
  success: boolean
  message: string
}

/** 语音输入测试结果 */
export interface VoiceDictationTestResult {
  success: boolean
  message: string
}

/** 麦克风权限检查结果 */
export interface MicPermissionResult {
  status: 'granted' | 'denied' | 'not-determined' | 'unsupported'
  platform: NodeJS.Platform
}

/** 语音输入 IPC 通道常量 */
export const VOICE_DICTATION_IPC_CHANNELS = {
  GET_SETTINGS: 'voice-dictation:get-settings',
  UPDATE_SETTINGS: 'voice-dictation:update-settings',
  TEST_CONNECTION: 'voice-dictation:test-connection',
  TOGGLE: 'voice-dictation:toggle',
  START: 'voice-dictation:start',
  SEND_AUDIO: 'voice-dictation:send-audio',
  STOP: 'voice-dictation:stop',
  CANCEL: 'voice-dictation:cancel',
  PREVIEW: 'voice-dictation:preview',
  COMMIT: 'voice-dictation:commit',
  HIDE: 'voice-dictation:hide',
  RESIZE: 'voice-dictation:resize',
  SHOWN: 'voice-dictation:shown',
  TOGGLE_STOP: 'voice-dictation:toggle-stop',
  TRANSCRIPT: 'voice-dictation:transcript',
  STATE: 'voice-dictation:state',
  INDICATOR_STATE: 'voice-dictation:indicator-state',
  REPORT_VOLUME: 'voice-dictation:report-volume',
  REPORT_TRANSCRIPT: 'voice-dictation:report-transcript',
  INSERT_TEXT: 'voice-dictation:insert-text',
  ACK_INSERT_TEXT: 'voice-dictation:ack-insert-text',
  PREVIEW_TEXT: 'voice-dictation:preview-text',
  CLEAR_PREVIEW_TEXT: 'voice-dictation:clear-preview-text',
  CHECK_MIC_PERMISSION: 'voice-dictation:check-mic-permission',
  REQUEST_MIC_PERMISSION: 'voice-dictation:request-mic-permission',
} as const
