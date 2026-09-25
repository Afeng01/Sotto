# 呦呦 Sotto

独立常驻的 macOS 系统级语音输入应用：全局快捷键唤起，说完自动写入当前光标位置。纯 Swift/AppKit 原生实现，安装包约 556K。

## 功能

- **全局快捷键听写**：默认 `Ctrl + `` ` ``，在任意应用里唤起浮窗，不抢焦点、不打断当前工作
- **写入光标**：说完后自动把转写文本粘贴到当前应用的光标位置（失败自动回退剪贴板）
- **实时转写浮窗**：真实音量驱动的声波条，固定两行显示识别结果；超出内容自动向上滚动且不显示滚动条
- **听写历史**：最近 100 条记录，支持搜索、复制、清空
- **自定义热词**：豆包热词语料，人名、术语识别更准
- **开机自启 / 快捷键自定义**：设置内可视化录制
- **凭证安全**：API Key 存入 macOS Keychain，不落明文文件

## 安装

1. 下载 `Sotto-*.dmg`，把 Sotto.app 拖进「应用程序」
2. 首次打开前，在终端执行一次（应用未做 Apple 公证，微信/网盘传输会带隔离属性）：

```bash
sudo xattr -rd com.apple.quarantine /Applications/Sotto.app
```

3. 打开后按引导配置豆包 API Key，授予麦克风与辅助功能权限

## 开发

```bash
cd native
swift build            # 编译
./scripts/make-app.sh  # 打包 Sotto.app（release + 图标 + ad-hoc 签名）
```

产物在 `native/build/Sotto.app`；调试可用命令行：

```bash
.build/debug/Sotto check    # 测试豆包凭证连通性
.build/debug/Sotto status   # 查看当前配置
```

## 架构

```text
native/Sources/Sotto/
  main.swift               入口：子命令、菜单、生命周期
  DictationCoordinator.swift  听写状态机（idle/active/stopping）
  DoubaoAsrClient.swift    豆包流式 ASR 二进制 WebSocket 协议
  AudioCapture.swift       麦克风采集（AVAudioEngine → 16kHz/16bit PCM）
  TranscriptMerger.swift   多段转写合并
  TextInsertion.swift      写入光标（剪贴板 + CGEvent 粘贴）
  CapturePanel.swift       非聚焦浮窗（NSPanel）
  HotkeyCenter.swift       Carbon 全局快捷键
  SettingsPanel.swift      设置窗口（SwiftUI，五页）
  SettingsStore.swift      ~/.sotto/settings.json
  KeychainStore.swift      API Key 钥匙串存储
  HistoryStore.swift       ~/.sotto/history.json
  DesignTokens.swift       与设计稿对齐的共享色值
```

`src/` 下保留了早期 Electron 实现（已停用，仅作 UI 参照），主分支以 `native/` 为准。

## 已知限制

- 豆包凭证需要手动填写：火山引擎控制台 → 语音技术，复制 API Key（新版控制台只需这一项）
- 自动粘贴（写入光标）需要在系统设置中授予「辅助功能」权限
- 仅支持 macOS arm64（Apple Silicon）
