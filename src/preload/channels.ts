/** IPC 通道别名：preload 与 shared 包解耦，避免把主进程模块打进 preload bundle。 */

import { VOICE_APP_IPC_CHANNELS } from '../shared/ipc-channels'
import { VOICE_DICTATION_IPC_CHANNELS } from '@sotto/voice'

export const VOICE_APP_IPC = VOICE_APP_IPC_CHANNELS
export const VOICE_DICTATION_IPC = VOICE_DICTATION_IPC_CHANNELS
