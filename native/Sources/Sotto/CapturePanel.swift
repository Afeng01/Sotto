import AppKit
import SwiftUI
import Combine

/// 听写浮窗：非聚焦 NSPanel，屏幕底部居中，绝不抢走目标应用焦点。
///
/// 视觉以 Electron 版 0.1.2 的 src/renderer/VoiceCaptureApp.tsx 为基准，
/// 当前原生规格：宽 380、底边距 20、圆角 16、头部状态行、1px 分隔线、固定两行转写视口。
@MainActor
final class CapturePanel {
    private static let width: CGFloat = 380                 // CAPTURE_WIDTH（voice-capture-window.ts）
    private static let minHeight: CGFloat = 110             // CAPTURE_MIN_HEIGHT
    private static let bottomMargin: CGFloat = 20           // 底边距：鹿鸣拍板「只比 Dock 高一点点」（0.2.5）

    // MARK: 固定两行窗口（鹿鸣 0.2.5 拍板）：高度恒定不再伸缩，超出两行的内容向上滚出
    /// 转写区视口 = 两行（2×28），加上下 padding 8+12 正好装满
    fileprivate static let transcriptViewport: CGFloat = lineHeight * 2 + 20
    /// 窗口总高 = 头部区 41 + 转写视口 76 + 缓冲 6 = 123，从唤起到结束恒定不变
    private static let fixedWindowHeight: CGFloat = fixedHeight + lineHeight * 2 + 20 + windowBuffer
    private static let windowBuffer: CGFloat = 6            // WINDOW_HEIGHT_BUFFER
    private static let lineHeight: CGFloat = 28             // LINE_HEIGHT（leading-7）
    /// fixedHeight = 根容器垂直 padding（pb-3 = 12）+ 头部 28 + 1px 分隔线
    private static let fixedHeight: CGFloat = 12 + 28 + 1
    /// 保留 AppKit 防御性最大尺寸；正常展示始终由 fixedWindowHeight（123pt）决定。
    private static let contentMaxHeight: CGFloat = 153

    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()
    private var cancellables = Set<AnyCancellable>()
    /// 底边锚位（0.2.2 加固）：show/position 时锁定的目标底边 y，
    /// syncHeight 据此绝对计算 origin.y，不再增量推算
    private var bottomAnchorY: CGFloat = 0

    init() {
        // 转写变化后重申固定窗口尺寸与底边锚点，避免内容尺寸影响窗口几何。
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
            // 显式清空默认 sizingOptions，避免 SwiftUI 内容理想尺寸与 AppKit 窗口 frame 互相驱动。
            // 当前尺寸完全由 position/syncHeight 控制：固定 123pt，底边锚定；153pt 仅作防御性上限。
            hosting.sizingOptions = []
            panel.contentView = hosting
            panel.contentMinSize = NSSize(width: Self.width, height: Self.minHeight)
            panel.contentMaxSize = NSSize(width: Self.width, height: Self.contentMaxHeight)
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
        // 1:1 对齐 resizeCaptureWindow：每次调整都重新读取 workArea，绝对计算底边与
        // 水平居中，不从当前 frame 增量推算（增量式写法会把外部机制对 frame 的改动
        // 固化成漂移；绝对计算则每次自愈）。
        var frame = panel.frame
        if let screen = panel.screen {
            frame.origin.x = round(screen.visibleFrame.midX - size.width / 2)
            frame.origin.y = round(screen.visibleFrame.minY + Self.bottomMargin) // AppKit origin 即左下角：直接锚底边，向上生长
        } else {
            frame.origin.y = bottomAnchorY // bottomAnchorY 亦为底边语义
        }
        frame.size = size
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let size = desiredSize()
        // integral 化：origin/size 全取整，防分数字号（奇数屏宽中点、非整 Dock 高）
        // 与 backing scale 舍入漂移
        let x = round(visibleFrame.midX - size.width / 2)
        let y = round(visibleFrame.minY + Self.bottomMargin)
        bottomAnchorY = y
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    /// 窗口总高固定为两行规格（123pt），不依赖屏幕高度或转写长度。
    private func desiredSize() -> NSSize {
        NSSize(width: Self.width, height: Self.fixedWindowHeight)
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
/// → 1px 分隔线（mx-3.5 border/60）→ 转写区（15px、28 行高、左对齐、固定两行视口，
/// 超出内容自动上滚，最新一行始终可见）。
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
            .frame(height: CapturePanel.transcriptViewport) // 固定两行视口：满了向上滚，窗口不再变高
            .scrollIndicators(.hidden) // [scrollbar-width:none]
            .background(HideScrollers()) // AppKit 层直接关闭实际 scroller；长文本仍可滚动，但不占滚动条空间
            .onChange(of: viewModel.text) { _ in
                withAnimation(nil) { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }
}

/// 隐藏 SwiftUI ScrollView 背后的 NSScrollView 滚动条。
/// SwiftUI 的 background representable 与 NSScrollView 是同一 NSHostingView 下的兄弟，
/// 必须从共同宿主向下遍历子视图；只沿 representable 的 superview 向上找会永远找不到。
struct HideScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { _ = Self.hide(in: view) }
    }

    @discardableResult
    static func hide(in view: NSView) -> Int {
        var root = view
        while let parent = root.superview { root = parent }

        var stack = [root]
        var scrollViews: [NSScrollView] = []
        while let node = stack.popLast() {
            if let scroll = node as? NSScrollView { scrollViews.append(scroll) }
            stack.append(contentsOf: node.subviews)
        }
        for scroll in scrollViews {
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.verticalScroller?.isHidden = true
            scroll.horizontalScroller?.isHidden = true
        }
        return scrollViews.count
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

// MARK: - paneltest 复现 harness 专用只读接口（不参与正常路径）
extension CapturePanel {
    var testFrame: NSRect { panel?.frame ?? .zero }
    var testDesiredSize: NSSize { desiredSize() }
    var testMaxHeight: CGFloat { Self.fixedWindowHeight }

    /// 仅 paneltest 使用：模拟外部机制对窗口的微调（内容约束/像素对齐类：
    /// 顶边固定、高度增加 delta、底边下坠），用于验证 syncHeight 对外部校正的处理
    func testNudgeHeight(_ delta: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.y -= delta
        frame.size.height += delta
        panel.setFrame(frame, display: true)
    }

    /// paneltest：模拟系统「始终显示滚动条」，再验证产品隐藏逻辑能关掉实际 NSScroller。
    func testHideScrollers() -> (found: Int, forcedVisible: Bool, disabled: Bool, contentHeight: CGFloat, viewportHeight: CGFloat, widthBefore: CGFloat, widthAfter: CGFloat) {
        guard let root = panel?.contentView else { return (0, false, false, 0, 0, 0, 0) }
        var stack = [root]
        var scroll: NSScrollView?
        while let node = stack.popLast() {
            if let candidate = node as? NSScrollView { scroll = candidate; break }
            stack.append(contentsOf: node.subviews)
        }
        guard let scroll else { return (0, false, false, 0, 0, 0, 0) }

        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.layoutSubtreeIfNeeded()
        let forcedVisible = scroll.hasVerticalScroller
        let contentHeight = scroll.documentView?.frame.height ?? 0
        let viewportHeight = scroll.contentView.bounds.height
        let widthBefore = scroll.contentView.bounds.width
        let found = HideScrollers.hide(in: root)
        scroll.layoutSubtreeIfNeeded()
        let scrollerIsHidden = scroll.verticalScroller?.isHidden ?? true
        let disabled = !scroll.hasVerticalScroller && scrollerIsHidden
        let widthAfter = scroll.contentView.bounds.width
        return (found, forcedVisible, disabled, contentHeight, viewportHeight, widthBefore, widthAfter)
    }
}
