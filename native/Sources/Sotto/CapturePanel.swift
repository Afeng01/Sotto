import AppKit
import SwiftUI

/// 听写浮窗：非聚焦 NSPanel，底部居中，实时显示转写文本。
@MainActor
final class CapturePanel {
    private static let width: CGFloat = 380
    private static let minHeight: CGFloat = 110
    private static let maxHeight: CGFloat = 240
    private static let bottomMargin: CGFloat = 28

    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()

    var onClose: (() -> Void)?

    init() {
        viewModel.onCommit = { [weak self] text in
            guard !text.isEmpty else {
                self?.hide()
                return
            }
            let result = TextInsertion.pasteAtCursor(text)
            if !result.success {
                print("[听写] \(result.message)")
            }
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
            let hosting = NSHostingView(rootView: TranscriptPopoverView(viewModel: viewModel))
            panel.contentView = hosting
            self.panel = panel
        }

        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        panel.alphaValue = 1
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
        let height = min(Self.maxHeight, max(Self.minHeight, CGFloat(lines) * 24 + 40))
        return NSSize(width: Self.width, height: height)
    }
}

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var text = ""
    @Published var status = ""

    var onCommit: ((String) -> Void)?
}

struct TranscriptPopoverView: View {
    @ObservedObject var viewModel: TranscriptViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.status.isEmpty {
                Text(viewModel.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                Text(viewModel.text.isEmpty ? "正在听写…" : viewModel.text)
                    .font(.system(size: 15))
                    .foregroundColor(viewModel.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(10)
    }
}
