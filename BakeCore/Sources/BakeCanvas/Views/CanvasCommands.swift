import BakeGraph
import SwiftUI

/// What the menu bar can ask the focused canvas to do.
public struct CanvasActions {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let insertStressGraph: () -> Void
    /// Group Selection / Ungroup (custom nodes), and whether each would do anything right now.
    var group: () -> Void = {}
    var ungroup: () -> Void = {}
    var canGroup = false
    var canUngroup = false
    /// Make Feedback Group (issue 004): the selected chain inside a feedback loop, as one card.
    var feedbackGroup: () -> Void = {}
    var canFeedbackGroup = false
    /// Find a node by name and add it (the Add Node search).
    var searchNodes: () -> Void = {}
}

extension FocusedValues {
    @Entry public var canvasActions: CanvasActions?
}

/// Edit-menu grouping, View-menu zoom commands, and a debug-only command for performance checks.
public struct CanvasCommands: Commands {
    @FocusedValue(\.canvasActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Add Node…") { actions?.searchNodes() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(actions == nil)
            Button("Group Selection") { actions?.group() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(actions?.canGroup != true)
            Button("Ungroup") { actions?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(actions?.canUngroup != true)
            Button("Make Feedback Group") { actions?.feedbackGroup() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(actions?.canFeedbackGroup != true)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { actions?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(actions == nil)
            Button("Zoom Out") { actions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions == nil)
            Button("Actual Size") { actions?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions == nil)
            #if DEBUG
            Divider()
            Button("Replace with Stress Graph (100 Nodes)") { actions?.insertStressGraph() }
                .disabled(actions == nil)
            #endif
        }
    }
}
