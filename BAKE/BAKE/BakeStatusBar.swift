import AppKit
import BakeGraph
import BakeSession
import SwiftUI

/// The strip under the canvas: bake progress, the result, or what went wrong.
struct BakeStatusBar: View {
    let state: BakeState
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .idle:
                EmptyView()
            case .baking(let progress):
                ProgressView(value: progress).frame(width: 160)
                Text("Baking… \(progress.formatted(.percent.precision(.fractionLength(0))))").monospacedDigit()
                Button("Cancel", action: cancel).keyboardShortcut(".", modifiers: .command)
            case .finished(let outputs):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Baked \(outputs.map(\.lastPathComponent).formatted(.list(type: .and)))")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            case .failed(let issues):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(summary(of: issues))
            case .cancelled:
                Text("Bake cancelled.").foregroundStyle(.secondary)
            case .previewReady:
                Image(systemName: "play.circle.fill").foregroundStyle(.secondary)
                Text("Preview ready.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, state == .idle ? 0 : 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bakeStatus")
    }

    private func summary(of issues: GraphIssues) -> String {
        let onNodes = issues.nodes.count
        let parts = issues.general + (onNodes == 0 ? [] : [onNodes == 1 ? "1 node needs attention." : "\(onNodes) nodes need attention."])
        return parts.joined(separator: " ")
    }
}
