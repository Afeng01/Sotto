import AppKit
import SwiftUI
import Combine

/// 听写浮窗：非聚焦 NSPanel，屏幕底部居中，绝不抢走目标应用焦点。
///
/// 视觉 1:1 对齐 Electron 版 0.1.2 的 src/renderer/VoiceCaptureApp.tsx +
/// src/main/voice-capture-window.ts（宽 380、底部居中 margin 28、
/// 圆角 16 卡片、popover 米白底、头部 呦呦+状态行、1px 分隔线、15px/28 行高转写区）。
@MainActor
final class CapturePanel {
    private static let width: CGFloat = 380                 // CAPTURE_WIDTH
    private static let minHeight: CGFloat = 110             // CAPTURE_MIN_HEIGHT
    private static let maxHeight: CGFloat = 187             // 固定高度 55 + 转写区 4 行（use-voice-window-layout.ts POPOVER_MAX_TOTAL_LINES）
    private static let bottomMargin: CGFloat = 28           // CAPTURE_BOTTOM_MARGIN

    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // 转写变化时同步窗口高度（对齐 resizeCaptureWindow：内容高度驱动，底部对齐不变）
        viewModel.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncHeight() }
            .store(in: &cancellables)
    }

    var transcript: String {
        get { viewModel.text }
        set { viewModel.text = newValue }
    }

    var status: String {
        get { viewModel.status }
        set { viewModel.status = newValue }
    }

    var volume: Double {
        get { viewModel.volume }
        set { viewModel.volume = newValue }
    }

    var statusIsError: Bool {
        get { viewModel.statusIsError }
        set { viewModel.statusIsError = newValue }
    }

    func show() {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.minHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.isMovable = false
            panel.hidesOnDeactivate = false
            panel.worksWhenModal = true
            let hosting = NSHostingView(rootView: TranscriptPopoverView(viewModel: viewModel))
            // 根因修复（高度失控）：NSHostingView 默认 sizingOptions =
            // [.minSize, .intrinsicContentSize, .maxSize]，会把 SwiftUI 内容尺寸转成窗口
            // 约束。说话久了转写超过 4 行时，ScrollView 内容高度变化（macOS 15 上经
            // NSScrollView 约束传递）与 syncHeight 的 setFrame 赛跑，AppKit 为满足约束
            // 把窗口从顶边向下撑大，底边坠过 Dock。置空后窗口尺寸唯一归 syncHeight/
            // position 驱动：底边固定、向上生长、187pt 封顶。
            hosting.sizingOptions = []
            panel.contentView = hosting
            // AppKit 层硬约束：任何路径的窗口高度都不允许越过 187pt 预算
            panel.contentMinSize = NSSize(width: Self.width, height: Self.minHeight)
            panel.contentMaxSize = NSSize(width: Self.width, height: Self.maxHeight)
            self.panel = panel
        }

        position(panel)
        // 只展示，不激活、不设为 key：目标应用的焦点和光标保持不动
        panel.orderFrontRegardless()
    }

    /// 浮窗是否可见（orderOut 后为 false）：音量等回调据此丢弃，避免隐藏后仍驱动 UI
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func syncHeight() {
        guard let panel, panel.isVisible else { return }
        let size = desiredSize()
        guard panel.frame.size != size else { return }
        var frame = panel.frame
        frame.origin.y -= (size.height - frame.height) // 底边保持不动
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let size = desiredSize()
        let x = visibleFrame.midX - size.width / 2
        let y = visibleFrame.minY + Self.bottomMargin
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    /// 窗口总高：根容器底边距 12 + 头部 28 + 分隔线 1 + 转写区 + 缓冲 14（对齐 use-voice-window-layout.ts）
    private func desiredSize() -> NSSize {
        let lines = min(4, Self.transcriptLineCount(of: viewModel.text))
        let transcriptBox = max(34, 8 + CGFloat(lines) * 28 + 12) // pt-2 + 行高 28 + pb-3
        let height = min(Self.maxHeight, max(Self.minHeight, 55 + transcriptBox))
        return NSSize(width: Self.width, height: height)
    }

    /// 按Electron 版转写区可用宽度（380 - 根边距 12×2 - 描边 1×2 - px-3.5 14×2 = 326）估算换行行数
    static func transcriptLineCount(of raw: String) -> Int {
        guard !raw.isEmpty else { return 1 }
        let font = NSFont.systemFont(ofSize: 15)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let attr = NSAttributedString(string: raw, attributes: [.font: font, .paragraphStyle: paragraph])
        let usableWidth: CGFloat = 326
        let bounds = attr.boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let singleLine = attr.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        guard singleLine > 0 else { return 1 }
        return max(1, Int(ceil(bounds.height / singleLine - 0.05)))
    }
}

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var text = ""
    @Published var status = ""
    @Published var statusIsError = false
    /// 实时音量（0…1），由 AudioCapture.onVolume 驱动（对齐 Electron 真实音量声波）
    @Published var volume: Double = 0
}

/// 浮窗视觉：结构复刻 Electron 版 VoiceCaptureApp.tsx 的 return JSX（L355-411）。
/// 透明根容器（px-3 pb-3）→ 圆角 16 卡片（bg-popover + border/70 + shadow-lg）
/// → 头部行（图标/波形 + 呦呦 + 状态文案 + 错误时“打开设置”）
/// → 1px 分隔线（mx-3.5 border/60）→ 转写区（15px、28 行高、左对齐、最多 4 行滚动）。
struct TranscriptPopoverView: View {
    @ObservedObject var viewModel: TranscriptViewModel

    /// Electron 无真实音量数据时的兜底：原生拿不到 AudioCapture 的音量
    /// （不允许改动其逻辑），用动画波形保持观感一致。
    private enum Phase {
        case connecting, recording, stopping, error
    }

    private var phase: Phase {
        if viewModel.statusIsError { return .error }
        if viewModel.status.isEmpty { return .recording }
        if viewModel.status.contains("提交") || viewModel.status.contains("整理") { return .stopping }
        return .connecting
    }

    /// Electron 版头部文案（VoiceCaptureApp.tsx L67/L114/L385）
    private var headerMessage: String {
        switch phase {
        case .error: return viewModel.status
        case .recording: return "正在听写"
        case .stopping: return "正在收尾识别..."
        case .connecting: return viewModel.status == "正在连接豆包 ASR..." || viewModel.status == "等待麦克风权限…" ? "准备麦克风..." : viewModel.status
        }
    }

    private var placeholder: String {
        phase == .connecting ? "准备麦克风..." : "请开始说话" // VoiceCaptureApp.tsx L397
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            card
        }
        .padding(.horizontal, 12)  // px-3
        .padding(.bottom, 12)      // pb-3
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            divider
            transcriptBox
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous) // rounded-2xl
                .fill(Color.sottoPopover)                          // bg-popover
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.sottoBorder.opacity(0.7), lineWidth: 1) // border-border/70
        )
        // shadow-lg: 0 10px 15px -3px / 0 4px 6px -4px rgb(0 0 0 / 0.1)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 10)
        .shadow(color: .black.opacity(0.1), radius: 3, y: 4)
    }

    // MARK: 头部（flex items-center gap-2 px-3.5 pt-1.5 pb-1.5）

    private var header: some View {
        HStack(spacing: 8) {
            leadingIcon
            Text("呦呦")
                .font(.system(size: 12, weight: .semibold)) // text-xs font-semibold
                .foregroundColor(.sottoForeground)
            Text(headerMessage)
                .font(.system(size: 12))                    // text-xs
                .foregroundColor(.sottoMutedText)           // text-muted-foreground
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading) // min-w-0 flex-1 truncate
            if phase == .error {
                openSettingsButton
            }
        }
        .padding(.horizontal, 14)   // px-3.5
        .padding(.top, 6)           // pt-1.5
        .padding(.bottom, 6)        // pb-1.5
    }

    @ViewBuilder
    private var leadingIcon: some View {
        // size-4 的图标位（flex size-4 shrink-0 items-center justify-center）
        ZStack {
            switch phase {
            case .recording:
                VolumeWaveform(volume: viewModel.volume)
            case .connecting, .stopping:
                Spinner()   // Loader2 size-3.5 animate-spin text-primary
            case .error:
                Image(systemName: "mic")
                    .font(.system(size: 12))
                    .foregroundColor(.sottoDestructive)
            }
        }
        .frame(width: 16, height: 16)
    }

    private var openSettingsButton: some View {
        // VoiceCaptureApp.tsx L389-396：rounded-md border px-2 py-0.5 text-[11px]
        Button(action: {
            NotificationCenter.default.post(name: .sottoOpenSettings, object: nil)
        }) {
            Text("打开设置")
                .font(.system(size: 11))
                .foregroundColor(.sottoForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.sottoBorder, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        // mx-3.5 h-px bg-border/60
        Rectangle()
            .fill(Color.sottoBorder.opacity(0.6))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: 转写区（min-h-[34px] px-3.5 pt-2 pb-3 text-[15px] leading-7）

    private var transcriptBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(viewModel.text.isEmpty ? placeholder : viewModel.text)
                    .font(.system(size: 15))
                    .lineSpacing(8) // 15px 字面行高约 20 → 总行高 28（leading-7）
                    .foregroundColor(viewModel.text.isEmpty ? Color.sottoMutedText.opacity(0.6) : .sottoForeground)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("transcript")
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .frame(minHeight: 34, maxHeight: max(34, 8 + 4 * 28 + 12))
            .scrollIndicators(.hidden) // [scrollbar-width:none]
            .onChange(of: viewModel.text) { _ in
                withAnimation(nil) { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }
}

/// 录音中的音量波形（VoiceCaptureApp.tsx L368-375：5 根 3px 宽圆角条，间距 3px，primary 色）。
/// 高度 = max(4, vol * scale * 16)，vol 由 AudioCapture RMS 实时驱动（1:1 对齐 Electron）。
private struct VolumeWaveform: View {
    let volume: Double
    private let scales: [CGFloat] = [0.6, 1, 0.75, 0.9, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(scales.indices, id: \.self) { i in
                let v = max(0.05, min(1, volume))
                Capsule()
                    .fill(Color.sottoPrimary)
                    .frame(width: 3, height: max(4, round(v * scales[i] * 16)))
                    .animation(.linear(duration: 0.05), value: volume)
            }
        }
        .frame(height: 16, alignment: .center)
    }
}

/// 14px 旋转 spinner（Loader2 size-3.5 animate-spin）
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.15, to: 0.85)
                .stroke(Color.sottoPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(t * 360)) // 持续旋转，1 圈/秒（animate-spin）
        }
    }
}

extension Notification.Name {
    static let sottoOpenSettings = Notification.Name("sotto.openSettings")
}
