# 呦呦 Sotto

独立常驻的 macOS 系统级语音输入应用：全局快捷键唤起，说完自动写入当前光标位置。

## 功能

- **全局快捷键听写**：默认 `Ctrl + `` ` ``，随时唤起，无需打开任何窗口
- **写入光标**：说完后自动把转写文本粘贴到当前应用的光标位置（失败自动回退剪贴板）
- **实时转写浮窗**：非聚焦浮窗实时显示识别结果，不打断当前工作
- **菜单栏常驻**：无 Dock 图标，托盘直达设置
- **开机自启**：可在设置中开启
- **豆包流式 ASR**：火山引擎豆包语音识别，支持自定义热词、连接模式、识别语言
- **凭证加密存储**：API Key / Access Token 通过 macOS Keychain（safeStorage）加密后落盘

## 安装提示（未签名版本）

应用未做 Apple 开发者签名/公证，经微信、网盘等渠道传输后首次打开会提示「“Sotto”已损坏，无法打开」。在终端执行以下命令后即可正常打开：

```bash
sudo xattr -rd com.apple.quarantine /Applications/Sotto.app
```

## 开发

```bash
bun install
bun run dev        # 启动 dev（vite + electron）
bun run typecheck
bun test
bun run dist:mac   # 打包 arm64 dmg
```

## 架构

```text
src/
  main/                  主进程
    index.ts             入口：托盘、设置窗口、生命周期
    voice-capture-window.ts  听写采集浮窗（非聚焦、置顶）
    shortcuts.ts         全局快捷键
    settings-store.ts    ~/.sotto/settings.json（原子写 + 加密）
    ipc.ts               IPC handlers
  preload/               contextBridge
  renderer/
    VoiceCaptureApp.tsx  听写采集窗口 UI
    SettingsApp.tsx      设置窗口 UI
  voice-dictation/       语音核心能力
    main/                豆包 ASR WebSocket、光标粘贴（osascript）
    renderer/            音频采集工具、转写合并
    types.ts             共享类型与 IPC 通道
```

## 已知限制

- 豆包凭证需要手动填写：火山引擎控制台 → 语音技术 → 应用管理，复制 APP ID 与 Access Token。
- 自动粘贴（写入光标）需要在系统设置中授予「辅助功能」权限。
- 仅支持 macOS arm64 打包；Windows/Linux 待适配。
