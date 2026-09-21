import AppKit
import SwiftUI

/// 听写浮窗：非聚焦 NSPanel，屏幕底部居中，绝不抢走目标应用焦点。
@MainActor
final class CapturePanel {
    private static let width: CGFloat = 380
    private static let minHeight: CGFloat = 96
    private static let maxHeight: CGFloat = 240
    private static let bottomMargin: CGFloat = 28

    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()

    init() {
        viewModel.onCommit = { [weak self] _ in
            self?.hide()
        }
    }

    var transcript: String {
        get { viewModel.text }
        set { viewModel.text = newValue }
    }

    var status: String {
        get { viewModel.status }
        set { viewModel.status = newValue }
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
            panel.contentView = hosting
            self.panel = panel
        }

        position(panel)
        // 只展示，不激活、不设为 key：目标应用的焦点和光标保持不动
        panel.orderFrontRegardless()
    }

    func commit() {
        viewModel.onCommit?(viewModel.text)
    }

    func hide() {
        panel?.orderOut(nil)
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

    private func desiredSize() -> NSSize {
        let lines = max(1, viewModel.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let height = min(Self.maxHeight, max(Self.minHeight, CGFloat(lines) * 24 + 56))
        return NSSize(width: Self.width, height: height)
    }
}

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var text = ""
    @Published var status = ""
    @Published var statusIsError = false

    var onCommit: ((String) -> Void)?
}

/// 浮窗视觉（对齐 Electron 版：浅蓝米白底 210 45% 97%、圆角卡片、描边、柔和阴影）
struct TranscriptPopoverView: View {
    @ObservedObject var viewModel: TranscriptViewModel

    static let popoverBg = Color(red: 0.957, green: 0.969, blue: 0.984) // hsl(210 45% 97%)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.status.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.statusIsError ? Color.red : Color.sottoPrimary)
                        .frame(width: 6, height: 6)
                    Text(viewModel.status)
                        .font(.system(size: 11))
                        .foregroundColor(viewModel.statusIsError ? Color.sottoDestructive : Color.sottoMutedText)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                if viewModel.text.isEmpty {
                    Text("正在听写…")
                        .font(.system(size: 15))
                        .foregroundColor(Color.sottoMutedText)
                } else {
                    Text(viewModel.text)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Self.popoverBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.sottoBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .padding(8)
    }
}
