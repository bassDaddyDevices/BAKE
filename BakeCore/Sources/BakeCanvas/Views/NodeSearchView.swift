import BakeGraph
import SwiftUI

/// Something the node search can add: a built-in node, or one of the document's custom nodes.
enum NodeSearchItem: Hashable, Identifiable {
    case kind(NodeKind)
    case custom(UUID, name: String)

    var id: Self { self }

    var title: String {
        switch self {
        case .kind(let kind): kind.title
        case .custom(_, let name): name
        }
    }

    var detail: String {
        switch self {
        case .kind(let kind): kind.menuPath
        case .custom: NodeCategory.custom.title
        }
    }
}

/// Add Node by typing: a field and the matching nodes. Return adds the highlighted one, the arrow
/// keys move the highlight, a click adds the one clicked, and Escape closes the popover.
struct NodeSearchView: View {
    let kinds: [NodeKind]
    let customNodes: [CustomNodeDefinition]
    let add: (NodeSearchItem) -> Void
    @State private var query = ""
    @State private var highlighted: NodeSearchItem?
    @FocusState private var isFieldFocused: Bool

    private var results: [NodeSearchItem] {
        NodeSearch.kinds(matching: query, among: kinds).map(NodeSearchItem.kind)
            + customNodes.filter { NodeSearch.matches(query, name: $0.name) }.map { .custom($0.id, name: $0.name) }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Search nodes", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .padding(10)
                .onSubmit {
                    if let item = highlighted ?? results.first { add(item) }
                }
                .onKeyPress(.downArrow) { moveHighlight(by: 1, in: results) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1, in: results) }
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { item in
                                row(item, isHighlighted: item == highlighted)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: highlighted) {
                        if let highlighted { proxy.scrollTo(highlighted) }
                    }
                }
            }
        }
        .frame(width: 300, height: 360)
        .onAppear {
            isFieldFocused = true
            highlighted = results.first
        }
        .onChange(of: query) { highlighted = self.results.first }
    }

    private func row(_ item: NodeSearchItem, isHighlighted: Bool) -> some View {
        Button { add(item) } label: {
            HStack {
                Text(item.title)
                Spacer()
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = item } }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.detail)
    }

    private func moveHighlight(by step: Int, in results: [NodeSearchItem]) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        let current = highlighted.flatMap(results.firstIndex) ?? -step
        highlighted = results[min(max(current + step, 0), results.count - 1)]
        return .handled
    }
}
