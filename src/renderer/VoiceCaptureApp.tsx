/**
 * VoiceCaptureApp — Sotto（呦呦） 听写采集浮窗
 *
 * 非聚焦置顶浮窗：实时转写 + 音量波形，提交统一走主进程外部输出（光标粘贴 → 剪贴板回退）。
 * 出错时保持浮窗可见并给出“打开设置”入口，避免用户以为应用无响应。
 */

import * as React from 'react'
import { Check, Clipboard, Loader2, Mic, Square, X } from 'lucide-react'
import type { VoiceDictationCommitResult, VoiceDictationSettings, VoiceDictationStateEvent } from '@sotto/voice'
import { CHUNK_BYTES, concatAudioBuffers, floatTo16BitPcm, splitChunk } from '@sotto/voice/renderer'
import { mergeVoiceDictationTranscript, type VoiceDictationTranscriptMergeState } from '@sotto/voice/renderer'
import { useVoiceWindowLayout } from '@sotto/voice/renderer'
import { resumeAudioContextForCapture } from '@sotto/voice/renderer'

const MAX_QUEUED_CHUNKS = 60
const STOP_COMMIT_TIMEOUT_MS = 1400
const FINAL_COMMIT_DELAY_MS = 180
const RESULT_VISIBLE_MS = 1200

export function VoiceCaptureApp(): React.ReactElement {
  const [sessionId, setSessionId] = React.useState<string | null>(null)
  const [status, setStatus] = React.useState<VoiceDictationStateEvent['status']>('idle')
  const [message, setMessage] = React.useState('等待快捷键唤起')
  const [transcript, setTranscript] = React.useState('')
  const [volume, setVolume] = React.useState(0)
  const [commitResult, setCommitResult] = React.useState<VoiceDictationCommitResult | null>(null)
  const [hotkeyLabel, setHotkeyLabel] = React.useState('')

  const sessionIdRef = React.useRef<string | null>(null)
  const transcriptTextRef = React.useRef('')
  const transcriptMergeStateRef = React.useRef<VoiceDictationTranscriptMergeState>({
    committedText: '',
    currentSessionText: '',
    currentSessionId: '',
  })
  const streamRef = React.useRef<MediaStream | null>(null)
  const audioContextRef = React.useRef<AudioContext | null>(null)
  const sourceRef = React.useRef<MediaStreamAudioSourceNode | null>(null)
  const processorRef = React.useRef<ScriptProcessorNode | null>(null)
  const pendingAudioRef = React.useRef<ArrayBuffer[]>([])
  const queuedAudioRef = React.useRef<ArrayBuffer[]>([])
  const asrReadyRef = React.useRef(false)
  const stoppingRef = React.useRef(false)
  const settingsRef = React.useRef<VoiceDictationSettings | null>(null)
  const commitTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null)
  const commitInFlightRef = React.useRef(false)
  const recordingAttemptRef = React.useRef(0)
  const audioCaptureReadyRef = React.useRef(false)
  const lastReportedVolumeAtRef = React.useRef(0)
  const discardTranscriptRef = React.useRef(false)

  const discardCurrentTranscript = React.useCallback(() => {
    discardTranscriptRef.current = true
    sessionIdRef.current = null
  }, [])

  const {
    rootRef,
    panelRef,
    headerRef,
    hintBarRef,
    transcriptBoxRef,
    transcriptMaxHeight,
  } = useVoiceWindowLayout({
    commitResultMessage: commitResult?.message ?? null,
    message,
    status,
    transcript,
  }, {
    resizeWindow: (input) => window.voiceAPI.resizeVoiceDictation(input),
  })

  React.useEffect(() => {
    document.body.style.background = 'transparent'
    document.documentElement.style.background = 'transparent'
    document.body.style.overflow = 'hidden'
    document.body.style.margin = '0'
    document.body.style.padding = '0'
  }, [])

  React.useEffect(() => {
    window.voiceAPI.getVoiceDictationSettings()
      .then((settings) => {
        settingsRef.current = settings
      })
      .catch(console.error)
    window.voiceAPI.getAppSettings()
      .then((appConfig) => setHotkeyLabel(appConfig.hotkey ? prettyAccelerator(appConfig.hotkey) : ''))
      .catch(console.error)
  }, [])

  const cleanupAudio = React.useCallback((clearBufferedAudio = true) => {
    processorRef.current?.disconnect()
    processorRef.current = null
    sourceRef.current?.disconnect()
    sourceRef.current = null
    audioContextRef.current?.close().catch(() => {})
    audioContextRef.current = null
    streamRef.current?.getTracks().forEach((track) => track.stop())
    streamRef.current = null
    if (clearBufferedAudio) {
      pendingAudioRef.current = []
      queuedAudioRef.current = []
      asrReadyRef.current = false
      audioCaptureReadyRef.current = false
    }
    setVolume(0)
  }, [])

  const sendAudioChunk = React.useCallback((sid: string, chunk: ArrayBuffer) => {
    if (!asrReadyRef.current) {
      queuedAudioRef.current.push(chunk)
      if (queuedAudioRef.current.length > MAX_QUEUED_CHUNKS) {
        queuedAudioRef.current.shift()
      }
      return
    }
    window.voiceAPI.sendVoiceDictationAudio({ sessionId: sid, data: chunk }).catch(console.error)
  }, [])

  const flushQueuedAudio = React.useCallback(() => {
    const currentSessionId = sessionIdRef.current
    if (!currentSessionId) return
    const chunks = queuedAudioRef.current
    queuedAudioRef.current = []
    for (const chunk of chunks) {
      sendAudioChunk(currentSessionId, chunk)
    }
  }, [sendAudioChunk])

  const flushPendingAudio = React.useCallback(() => {
    const currentSessionId = sessionIdRef.current
    if (!currentSessionId || pendingAudioRef.current.length === 0) return
    const audio = concatAudioBuffers(pendingAudioRef.current)
    pendingAudioRef.current = []
    if (audio.byteLength > 0) {
      sendAudioChunk(currentSessionId, audio)
    }
  }, [sendAudioChunk])

  const commitAndHide = React.useCallback(async () => {
    if (commitInFlightRef.current) return
    commitInFlightRef.current = true
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current)
      commitTimerRef.current = null
    }
    const text = transcriptTextRef.current.trim()
    const asrSessionId = sessionIdRef.current
    discardCurrentTranscript()
    if (!text) {
      setMessage('没有识别到语音内容')
      cleanupAudio()
      if (asrSessionId) {
        await window.voiceAPI.cancelVoiceDictation({ sessionId: asrSessionId }).catch(console.error)
      }
      await window.voiceAPI.hideVoiceDictation().catch(console.error)
      setStatus('idle')
      return
    }

    setStatus('stopping')
    setMessage('正在输出文本...')
    try {
      const result = await window.voiceAPI.commitVoiceDictation({ sessionId: asrSessionId ?? '', text })
      setCommitResult(result)
      setStatus('completed')
      setMessage(result.message)
      cleanupAudio()
      // 让用户短暂看到输出结果（已复制/已写入），再隐藏窗口。
      setTimeout(() => {
        void window.voiceAPI.hideVoiceDictation().then(() => {
          setStatus('idle')
          setMessage('等待快捷键唤起')
        }).catch(console.error)
      }, RESULT_VISIBLE_MS)
    } catch (error) {
      commitInFlightRef.current = false
      const textMessage = error instanceof Error ? error.message : '未知错误'
      setStatus('error')
      setMessage(`输出失败: ${textMessage}`)
    }
  }, [cleanupAudio, discardCurrentTranscript])

  const scheduleCommit = React.useCallback((delay: number) => {
    if (commitInFlightRef.current) return
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current)
    }
    commitTimerRef.current = setTimeout(() => {
      commitAndHide().catch(console.error)
    }, delay)
  }, [commitAndHide])

  const stopRecording = React.useCallback(async () => {
    if (stoppingRef.current) return
    stoppingRef.current = true
    const currentSessionId = sessionIdRef.current
    setStatus('stopping')
    setMessage('正在收尾识别...')
    cleanupAudio(false)
    flushPendingAudio()
    flushQueuedAudio()
    if (currentSessionId) {
      window.voiceAPI.stopVoiceDictation({ sessionId: currentSessionId }).catch(console.error)
    }
    scheduleCommit(STOP_COMMIT_TIMEOUT_MS)
  }, [cleanupAudio, flushPendingAudio, flushQueuedAudio, scheduleCommit])

  const cancelAndHide = React.useCallback(() => {
    if (commitInFlightRef.current) return
    recordingAttemptRef.current += 1
    stoppingRef.current = true
    const currentSessionId = sessionIdRef.current
    discardCurrentTranscript()
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current)
      commitTimerRef.current = null
    }
    window.voiceAPI.hideVoiceDictation().catch(console.error)
    cleanupAudio()
    if (currentSessionId) {
      window.voiceAPI.cancelVoiceDictation({ sessionId: currentSessionId }).catch(console.error)
    }
  }, [cleanupAudio, discardCurrentTranscript])

  const abortCurrentSession = React.useCallback((keepWindowVisible = false) => {
    recordingAttemptRef.current += 1
    stoppingRef.current = true
    const currentSessionId = sessionIdRef.current
    discardCurrentTranscript()
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current)
      commitTimerRef.current = null
    }
    cleanupAudio()
    if (currentSessionId) {
      window.voiceAPI.cancelVoiceDictation({ sessionId: currentSessionId }).catch(console.error)
    }
    if (!keepWindowVisible) {
      window.voiceAPI.hideVoiceDictation().catch(console.error)
    }
  }, [cleanupAudio, discardCurrentTranscript])

  React.useEffect(() => {
    if (status !== 'error') return
    // 出错时保留浮窗展示原因与操作入口，由用户手动关闭。
    abortCurrentSession(true)
  }, [abortCurrentSession, status])

  const requestMicrophoneStream = React.useCallback(async (): Promise<MediaStream> => {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error('当前环境不支持麦克风采集')
    }
    try {
      return await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: { ideal: 1 },
          echoCancellation: { ideal: true },
          noiseSuppression: { ideal: true },
          autoGainControl: { ideal: true },
        },
      })
    } catch (error) {
      if (isConstraintError(error)) {
        return navigator.mediaDevices.getUserMedia({ audio: true })
      }
      throw error
    }
  }, [])

  const markAudioCaptureReady = React.useCallback(() => {
    if (audioCaptureReadyRef.current) return
    audioCaptureReadyRef.current = true
    setStatus('recording')
    setMessage('正在听写')
  }, [])

  const startAudioCapture = React.useCallback(async (attempt: number) => {
    const stream = await requestMicrophoneStream()
    if (attempt !== recordingAttemptRef.current || stoppingRef.current) {
      stream.getTracks().forEach((track) => track.stop())
      return
    }
    streamRef.current = stream

    const AudioContextCtor = window.AudioContext || window.webkitAudioContext
    if (!AudioContextCtor) {
      throw new Error('当前环境不支持音频处理')
    }

    const audioContext = new AudioContextCtor()
    if (attempt !== recordingAttemptRef.current || stoppingRef.current) {
      stream.getTracks().forEach((track) => track.stop())
      await audioContext.close().catch(() => {})
      return
    }
    audioContextRef.current = audioContext
    const source = audioContext.createMediaStreamSource(stream)
    sourceRef.current = source
    const processor = audioContext.createScriptProcessor(4096, 1, 1)
    processorRef.current = processor

    processor.onaudioprocess = (event) => {
      if (!sessionIdRef.current || stoppingRef.current) return
      const input = event.inputBuffer.getChannelData(0)
      let peak = 0
      for (let i = 0; i < input.length; i += 1) {
        peak = Math.max(peak, Math.abs(input[i] ?? 0))
      }
      const normalizedVolume = Math.min(1, peak * 4)
      setVolume(normalizedVolume)
      const now = performance.now()
      if (now - lastReportedVolumeAtRef.current >= 80) {
        lastReportedVolumeAtRef.current = now
      }

      const pcm = floatTo16BitPcm(input, audioContext.sampleRate)
      pendingAudioRef.current.push(pcm)
      let merged = concatAudioBuffers(pendingAudioRef.current)
      const nextPending: ArrayBuffer[] = []
      while (merged.byteLength >= CHUNK_BYTES) {
        const { chunk, rest } = splitChunk(merged, CHUNK_BYTES)
        if (!chunk) break
        sendAudioChunk(sessionIdRef.current, chunk)
        merged = rest
      }
      if (merged.byteLength > 0) nextPending.push(merged)
      pendingAudioRef.current = nextPending
    }

    source.connect(processor)
    processor.connect(audioContext.destination)
    await resumeAudioContextForCapture(audioContext)
    if (!stream.getAudioTracks().some((track) => track.readyState === 'live' && track.enabled)) {
      throw new Error('麦克风未就绪，请检查系统麦克风权限与设备连接')
    }

    if (attempt === recordingAttemptRef.current && !stoppingRef.current) {
      markAudioCaptureReady()
    }
  }, [markAudioCaptureReady, requestMicrophoneStream, sendAudioChunk])

  const startRecording = React.useCallback(async () => {
    const refreshSettings = window.voiceAPI.getVoiceDictationSettings()
      .then((latest) => {
        settingsRef.current = latest
        return latest
      })
      .catch((error) => {
        if (settingsRef.current?.enabled) {
          console.warn('[听写] 刷新设置失败，继续使用已缓存设置:', error)
          return settingsRef.current
        }
        throw error
      })

    stoppingRef.current = false
    discardTranscriptRef.current = false
    commitInFlightRef.current = false
    if (commitTimerRef.current) {
      clearTimeout(commitTimerRef.current)
      commitTimerRef.current = null
    }
    asrReadyRef.current = false
    audioCaptureReadyRef.current = false
    lastReportedVolumeAtRef.current = 0
    queuedAudioRef.current = []
    pendingAudioRef.current = []
    setTranscript('')
    transcriptTextRef.current = ''
    transcriptMergeStateRef.current = {
      committedText: '',
      currentSessionText: '',
      currentSessionId: '',
    }
    setCommitResult(null)
    setStatus('connecting')
    setMessage('准备麦克风...')
    const recordingAttempt = ++recordingAttemptRef.current

    const isCurrentAttempt = (): boolean => recordingAttempt === recordingAttemptRef.current
    const shouldBeginRecording = (): boolean => isCurrentAttempt() && !stoppingRef.current
    const cachedSettings = settingsRef.current
    const settings = cachedSettings?.enabled ? cachedSettings : await refreshSettings
    if (!shouldBeginRecording()) return
    settingsRef.current = settings
    if (!settings.enabled) {
      setStatus('error')
      setMessage('语音输入未启用，请在设置中检查')
      cleanupAudio()
      return
    }
    if (!settings.appId || !settings.accessToken) {
      setStatus('error')
      setMessage('尚未配置豆包凭证，请打开设置导入')
      cleanupAudio()
      return
    }

    const permission = await window.voiceAPI.checkMicrophonePermission()
    if (!shouldBeginRecording()) return
    if (permission.status === 'denied') {
      setStatus('error')
      setMessage('麦克风权限已被系统阻止，请在系统设置中允许呦呦访问麦克风')
      return
    }
    if (permission.status === 'not-determined') {
      const requested = await window.voiceAPI.requestMicrophonePermission()
      if (!shouldBeginRecording()) return
      if (requested.status !== 'granted') {
        setStatus('error')
        setMessage('需要麦克风权限才能使用语音输入')
        return
      }
    }

    if (!shouldBeginRecording()) return
    const nextSessionId = crypto.randomUUID()
    setSessionId(nextSessionId)
    sessionIdRef.current = nextSessionId

    const audioCapture = startAudioCapture(recordingAttempt).catch((error) => {
      if (!isCurrentAttempt()) return
      const textMessage = getMicrophoneErrorMessage(error)
      setStatus('error')
      setMessage(textMessage)
      abortCurrentSession(true)
      throw error
    })

    window.voiceAPI.startVoiceDictation({ sessionId: nextSessionId })
      .then(() => {
        if (!isCurrentAttempt() || sessionIdRef.current !== nextSessionId) {
          window.voiceAPI.cancelVoiceDictation({ sessionId: nextSessionId }).catch(console.error)
          return
        }
        asrReadyRef.current = true
        flushQueuedAudio()
        if (stoppingRef.current) {
          flushPendingAudio()
          flushQueuedAudio()
          window.voiceAPI.stopVoiceDictation({ sessionId: nextSessionId }).catch(console.error)
          scheduleCommit(STOP_COMMIT_TIMEOUT_MS)
          return
        }
      })
      .catch((error) => {
        if (!isCurrentAttempt() || sessionIdRef.current !== nextSessionId || stoppingRef.current) return
        const textMessage = error instanceof Error ? error.message : '未知错误'
        setStatus('error')
        setMessage(textMessage)
        abortCurrentSession(true)
      })

    await audioCapture
  }, [abortCurrentSession, cleanupAudio, flushPendingAudio, flushQueuedAudio, scheduleCommit, startAudioCapture])

  React.useEffect(() => {
    const cleanupShown = window.voiceAPI.onVoiceDictationShown(() => {
      startRecording().catch((error) => {
        const textMessage = error instanceof Error ? error.message : '未知错误'
        setStatus('error')
        setMessage(textMessage)
        cleanupAudio()
      })
    })

    const cleanupStop = window.voiceAPI.onVoiceDictationToggleStop(() => {
      stopRecording().catch(console.error)
    })

    const cleanupTranscript = window.voiceAPI.onVoiceDictationTranscript((event) => {
      if (discardTranscriptRef.current || event.sessionId !== sessionIdRef.current) return
      const mergedTranscript = mergeVoiceDictationTranscript(
        transcriptMergeStateRef.current,
        event.text,
        event.isFinal,
        event.sessionId,
      )
      transcriptMergeStateRef.current = mergedTranscript.state
      setTranscript(mergedTranscript.text)
      transcriptTextRef.current = mergedTranscript.text
      if (stoppingRef.current && event.isFinal) {
        scheduleCommit(FINAL_COMMIT_DELAY_MS)
      }
    })

    const cleanupState = window.voiceAPI.onVoiceDictationState((event) => {
      if (event.sessionId && event.sessionId !== sessionIdRef.current) return
      if (stoppingRef.current && event.status === 'error') return
      if (event.status === 'connecting' || event.status === 'recording') {
        if (!audioCaptureReadyRef.current) {
          setStatus('connecting')
          setMessage('准备麦克风...')
        }
        return
      }
      if (event.status === 'idle' && event.message === 'asr_session_ended') {
        if (stoppingRef.current) return
        // ASR 连接被服务端关闭（VAD 静音超时），仍在录音时自动重连。
        const reconnectAttempt = recordingAttemptRef.current
        const nextSessionId = crypto.randomUUID()
        const isCurrentReconnect = (): boolean =>
          recordingAttemptRef.current === reconnectAttempt &&
          sessionIdRef.current === nextSessionId
        setSessionId(nextSessionId)
        sessionIdRef.current = nextSessionId
        asrReadyRef.current = false
        queuedAudioRef.current = []
        window.voiceAPI.startVoiceDictation({ sessionId: nextSessionId })
          .then(() => {
            if (!isCurrentReconnect()) {
              window.voiceAPI.cancelVoiceDictation({ sessionId: nextSessionId }).catch(console.error)
              return
            }
            asrReadyRef.current = true
            flushQueuedAudio()
            if (stoppingRef.current) {
              window.voiceAPI.stopVoiceDictation({ sessionId: nextSessionId }).catch(console.error)
              scheduleCommit(STOP_COMMIT_TIMEOUT_MS)
            }
          })
          .catch((error) => {
            if (!isCurrentReconnect() || stoppingRef.current) return
            const textMessage = error instanceof Error ? error.message : '未知错误'
            setStatus('error')
            setMessage(textMessage)
          })
        return
      }
      setStatus(event.status)
      if (event.message) setMessage(event.message)
    })

    return () => {
      cleanupShown()
      cleanupStop()
      cleanupTranscript()
      cleanupState()
      recordingAttemptRef.current += 1
      const currentSessionId = sessionIdRef.current
      discardCurrentTranscript()
      if (currentSessionId) {
        window.voiceAPI.cancelVoiceDictation({ sessionId: currentSessionId }).catch(console.error)
      }
      if (commitTimerRef.current) clearTimeout(commitTimerRef.current)
      cleanupAudio()
      window.voiceAPI.hideVoiceDictation().catch(console.error)
    }
  }, [cleanupAudio, discardCurrentTranscript, scheduleCommit, startRecording, stopRecording])

  const busy = status === 'connecting' || status === 'recording' || status === 'stopping'

  return (
    <div ref={rootRef} className="box-border flex h-screen w-screen flex-col overflow-hidden rounded-xl bg-background px-2 pt-2 pb-1.5">
      <div ref={panelRef} className="flex min-h-0 w-full flex-col overflow-hidden">
        <div ref={headerRef} className="flex shrink-0 items-center justify-between px-2 pt-0.5 pb-2">
          <div className="flex items-center gap-3 min-w-0">
            <div
              className={`relative flex size-8 items-center justify-center rounded-full ${status === 'error' ? 'bg-destructive/10 text-destructive' : 'bg-primary/10 text-primary'}`}
            >
              {status === 'recording' && <span className="absolute inset-0 animate-ping rounded-full bg-primary/20" />}
              {status === 'connecting' || status === 'stopping'
                ? <Loader2 className="size-4 animate-spin" />
                : status === 'completed'
                  ? <Check className="size-4" />
                  : status === 'recording'
                    ? (
                      <div className="flex items-center gap-[3px] h-4">
                        {[0.6, 1, 0.75, 0.9, 0.5].map((scale, i) => (
                          <span
                            key={i}
                            className="w-[3px] rounded-full bg-primary transition-all duration-100"
                            style={{ height: `${Math.max(4, Math.round(volume * scale * 16))}px` }}
                          />
                        ))}
                      </div>
                    )
                    : <Mic className="size-4" />}
            </div>
            <div className="min-w-0">
              <div className="truncate text-sm font-medium text-foreground">呦呦 Sotto</div>
              <div className="truncate text-xs text-muted-foreground">{message}</div>
            </div>
          </div>

          <div className="flex items-center gap-1.5">
            {busy && (
              <button
                type="button"
                className="flex size-8 items-center justify-center rounded-full text-destructive hover:bg-muted"
                onClick={() => stopRecording().catch(console.error)}
                aria-label="停止听写"
              >
                <Square className="size-3.5" fill="currentColor" strokeWidth={0} />
              </button>
            )}
            <button
              type="button"
              className="flex size-8 items-center justify-center rounded-full text-muted-foreground hover:bg-muted"
              onClick={cancelAndHide}
              aria-label="取消听写"
            >
              <X className="size-4" />
            </button>
          </div>
        </div>

        <div className="min-h-0 px-2">
          <div className="overflow-hidden rounded-lg bg-muted/45">
            <div ref={hintBarRef} className="flex min-h-8 shrink-0 items-center justify-between gap-3 px-3 py-1.5 text-xs leading-4 text-muted-foreground">
              <span className="truncate">
                {status === 'error'
                  ? '解决后可关闭浮窗重试'
                  : hotkeyLabel
                    ? `再按 ${hotkeyLabel} 结束 · 写入光标 · 取消点 ✕`
                    : '再次按快捷键结束 · 写入光标 · 取消点 ✕'}
              </span>
              {status === 'error' ? (
                <button
                  type="button"
                  onClick={() => window.voiceAPI.openSettings()}
                  className="shrink-0 rounded-md border border-border px-2 py-0.5 text-[11px] text-foreground transition-colors hover:bg-muted"
                >
                  打开设置
                </button>
              ) : commitResult ? (
                <span className="flex shrink-0 items-center gap-1.5">
                  <Clipboard className="size-3.5" />
                  {commitResult.message}
                </span>
              ) : null}
            </div>
            <div className="h-px bg-border/70" />
            <div
              ref={transcriptBoxRef}
              className="box-border min-h-[34px] px-3 pt-2.5 pb-2.5 text-[15px] leading-7 text-foreground [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden"
              style={{
                maxHeight: transcriptMaxHeight ?? undefined,
                overflowY: 'auto',
              }}
            >
              <div className="whitespace-pre-wrap break-words overflow-hidden">
                {transcript || (
                  <span className="text-muted-foreground/60">
                    {status === 'connecting' ? '准备麦克风...' : '请开始说话'}
                  </span>
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function prettyAccelerator(accel: string): string {
  if (!accel) return ''
  const sym: Record<string, string> = { Control: '⌃', Alt: '⌥', Shift: '⇧', Super: '⌘' }
  const parts = accel.split('+')
  const key = parts.pop() ?? ''
  return [...parts.map((p) => sym[p] ?? p), key].join(' ')
}

function isConstraintError(error: unknown): boolean {
  return error instanceof DOMException &&
    (error.name === 'OverconstrainedError' || error.name === 'ConstraintNotSatisfiedError')
}

function getMicrophoneErrorMessage(error: unknown): string {
  if (error instanceof DOMException) {
    switch (error.name) {
      case 'NotAllowedError':
      case 'PermissionDeniedError':
        return '麦克风权限被系统阻止，请在系统设置中允许呦呦访问麦克风'
      case 'NotFoundError':
      case 'DevicesNotFoundError':
        return '没有检测到可用麦克风，请检查输入设备是否已连接并启用'
      case 'NotReadableError':
      case 'TrackStartError':
        return '麦克风当前无法读取，可能被其他应用占用或被系统隐私设置阻止'
      case 'OverconstrainedError':
      case 'ConstraintNotSatisfiedError':
        return '当前麦克风不支持请求的采集参数，请切换输入设备后重试'
      case 'SecurityError':
        return '当前窗口被系统阻止访问麦克风，请检查应用权限设置'
      default:
        break
    }
  }

  if (error instanceof Error) {
    return error.message
  }

  return '未知麦克风错误'
}
