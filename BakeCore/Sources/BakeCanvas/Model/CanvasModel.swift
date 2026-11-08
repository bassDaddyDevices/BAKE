import BakeGraph
import CoreGraphics
import Foundation
import Observation

/// Which face of a node card is showing. UI state only — not saved.
public enum NodePage: Sendable {
    case macro
    case modulation
}

/// How a pin draws while a wire is being dragged.
public enum PinHighlight: Sendable {
    case normal
    case source
    case candidate
    case target
    case unavailable
}

/// A wire being dragged from a pin.
public struct PendingWire: Equatable, Sendable {
    /// The fixed end. Dragging from an output (or a wired input) looks for inputs; dragging from
    /// a free input looks for outputs.
    public let anchor: PinRef
    public let anchorIsOutput: Bool
    /// The valid pin under the free end.
    public var target: PinRef?
    /// Pins the free end may connect to, worked out once when the drag starts.
    public let candidates: Set<PinRef>
    /// A wire picked up from an occupied input; removed when the drag ends unless dropped back.
    public let detached: Edge?
}

/// Canvas interaction state. The document is the source of truth; in-progress gestures live here
/// and reach the document in one write when they end, so every gesture is one undo step.
@MainActor @Observable
public final class CanvasModel {
    public var viewport = Viewport()
    /// Size of the canvas view, for zooming around its centre and placing new nodes.
    public var viewSize: CGSize = .zero
    public private(set) var selection: Set<NodeID> = []
    public private(set) var selectedEdge: Edge?
    /// Changes only when a drag starts, ends, or its target changes, so pins redraw rarely.
    public private(set) var pendingWire: PendingWire?
    /// The free end of the pending wire, in world coordinates. Changes every frame of a wire drag.
    public private(set) var wireEnd: CGPoint = .zero
    /// The canvas shows the inside of a custom node: cards offer promoting their controls to it.
    public var isEditingInside = false
    /// A wire begun without dragging (VoiceOver, keyboard): the pin activated first, waiting for its other end.
    public private(set) var wireStart: PinRef?

    private var pages: [NodeID: NodePage] = [:]
    private var draggedNodes: Set<NodeID> = []
    private var dragTranslation: CGSize = .zero
    private var parameterEdit: (node: NodeID, parameter: ParameterID, value: ParameterValue)?
    private var trimEdit: (node: NodeID, parameter: ParameterID, value: Double)?

    public init() {}

    // MARK: Display

    /// The project as drawn: committed state plus in-progress drags and edits.
    public func displayed(_ project: ProjectFile) -> ProjectFile {
        guard !draggedNodes.isEmpty || parameterEdit != nil || trimEdit != nil || pendingWire?.detached != nil else {
            return project
        }
        var shown = project
        if !draggedNodes.isEmpty {
            shown.moveNodes(draggedNodes, byX: Double(dragTranslation.width), y: Double(dragTranslation.height))
        }
        if let edit = parameterEdit {
            shown.setParameter(edit.parameter, of: edit.node, to: edit.value)
        }
        if let edit = trimEdit {
            shown.setTrim(edit.value, for: edit.parameter, of: edit.node)
        }
        if let detached = pendingWire?.detached {
            shown.removeEdge(detached)
        }
        return shown
    }

    // MARK: Pages

    public func page(of node: NodeID) -> NodePage {
        pages[node] ?? .macro
    }

    public func flip(_ node: NodeID) {
        pages[node] = page(of: node) == .macro ? .modulation : .macro
    }

    // MARK: Selection

    public func isSelected(_ node: NodeID) -> Bool {
        selection.contains(node)
    }

    public func select(_ node: NodeID, extending: Bool) {
        selectedEdge = nil
        if extending {
            if selection.remove(node) == nil { selection.insert(node) }
        } else {
            selection = [node]
        }
    }

    public func selectEdge(_ edge: Edge) {
        selection = []
        selectedEdge = edge
    }

    public func clearSelection() {
        selection = []
        selectedEdge = nil
    }

    /// A click on empty canvas selects the wire under it, or clears the selection.
    public func click(atView point: CGPoint, in project: ProjectFile) {
        let world = viewport.toWorld(point)
        if let edge = CanvasHitTest.edge(at: world, in: displayed(project), tolerance: 6 / viewport.scale) {
            selectEdge(edge)
        } else {
            clearSelection()
        }
    }

    public func deleteSelection(in project: inout ProjectFile) {
        if let edge = selectedEdge {
            project.removeEdge(edge)
        }
        // An Inputs or Outputs card stays: its ports are the custom node's pins.
        let removable = selection.filter { id in project.node(id).map { ![.customInput, .customOutput].contains($0.kind) } ?? false }
        if !removable.isEmpty {
            project.removeNodes(removable)
            for node in removable { pages[node] = nil }
        }
        clearSelection()
    }

    // MARK: Moving nodes

    /// `viewTranslation` is the drag's total translation in view points.
    public func dragNode(_ node: NodeID, by viewTranslation: CGSize) {
        if draggedNodes.isEmpty {
            if !selection.contains(node) {
                selection = [node]
                selectedEdge = nil
            }
            draggedNodes = selection
        }
        dragTranslation = CGSize(width: viewTranslation.width / viewport.scale, height: viewTranslation.height / viewport.scale)
    }

    public func endNodeDrag(in project: inout ProjectFile) {
        if dragTranslation != .zero {
            project.moveNodes(draggedNodes, byX: Double(dragTranslation.width), y: Double(dragTranslation.height))
        }
        draggedNodes = []
        dragTranslation = .zero
    }

    // MARK: Wiring

    /// Starts (on the first call) or updates a wire drag from `pin` to a point in view coordinates.
    public func dragWire(from pin: PinRef, toView point: CGPoint, in project: ProjectFile) {
        let world = viewport.toWorld(point)
        if pendingWire == nil {
            pendingWire = startWire(from: pin, in: project)
        }
        guard let wire = pendingWire else { return }
        wireEnd = world
        let hit = CanvasHitTest.pin(at: world, in: displayed(project), radius: 12 / viewport.scale)
        let target = hit.flatMap { wire.candidates.contains($0) ? $0 : nil }
        if target != wire.target {
            pendingWire?.target = target
        }
    }

    public func endWire(in project: inout ProjectFile) {
        guard let wire = pendingWire else { return }
        pendingWire = nil
        let connection = wire.target.map { target in
            wire.anchorIsOutput ? Edge(from: wire.anchor, to: target) : Edge(from: target, to: wire.anchor)
        }
        if let detached = wire.detached {
            if connection == detached { return } // dropped back where it was
            project.removeEdge(detached)
        }
        if let connection {
            try? project.connect(from: connection.from, to: connection.to)
        }
    }

    /// The pending wire's curve in world coordinates, snapped to its target when over one.
    public func pendingCurve(in project: ProjectFile) -> WireCurve? {
        guard let wire = pendingWire, let anchorNode = project.node(wire.anchor.node),
              let anchor = NodeLayout.anchor(of: wire.anchor.pin, on: anchorNode, in: project) else { return nil }
        let end = wire.target.flatMap { target in
            project.node(target.node).flatMap { NodeLayout.anchor(of: target.pin, on: $0, in: project) }
        } ?? wireEnd
        return wire.anchorIsOutput ? WireCurve(from: anchor, to: end) : WireCurve(from: end, to: anchor)
    }

    public func highlight(of pin: PinRef) -> PinHighlight {
        if pin == wireStart { return .source }
        guard let wire = pendingWire else { return .normal }
        if pin == wire.anchor { return .source }
        if pin == wire.target { return .target }
        return wire.candidates.contains(pin) ? .candidate : .unavailable
    }

    private func startWire(from pin: PinRef, in project: ProjectFile) -> PendingWire? {
        guard let definition = project.pin(pin) else { return nil }
        var base = project
        var anchor = pin
        var detached: Edge?
        if definition.direction == .input, let existing = project.edge(into: pin) {
            // Grabbing a wired input picks up that wire's end.
            detached = existing
            anchor = existing.from
            base.removeEdge(existing)
        }
        let anchorIsOutput = detached != nil || definition.direction == .output
        var candidates: Set<PinRef> = []
        for node in base.nodes {
            for other in NodeCatalog.pins(of: node, in: project).map({ PinRef(node: node.id, pin: $0.id) }) {
                let rejection = anchorIsOutput
                    ? base.checkConnection(from: anchor, to: other)
                    : base.checkConnection(from: other, to: anchor)
                if rejection == nil { candidates.insert(other) }
            }
        }
        return PendingWire(anchor: anchor, anchorIsOutput: anchorIsOutput, target: nil, candidates: candidates, detached: detached)
    }

    // MARK: Parameters

    public func preview(_ parameter: ParameterID, of node: NodeID, value: ParameterValue) {
        parameterEdit = (node, parameter, value)
    }

    public func commitParameter(in project: inout ProjectFile) {
        if let edit = parameterEdit {
            project.setParameter(edit.parameter, of: edit.node, to: edit.value)
        }
        parameterEdit = nil
    }

    public func previewTrim(_ trim: Double, for parameter: ParameterID, of node: NodeID) {
        trimEdit = (node, parameter, trim)
    }

    public func commitTrim(in project: inout ProjectFile) {
        if let edit = trimEdit {
            project.setTrim(edit.value, for: edit.parameter, of: edit.node)
        }
        trimEdit = nil
    }

    // MARK: Wiring without dragging

    /// Activating a pin (VoiceOver): the first starts a wire, a second pin finishes it, either way
    /// round; the same pin again cancels. Returns whether a wire was made.
    @discardableResult
    public func activatePin(_ pin: PinRef, in project: inout ProjectFile) -> Bool {
        guard let start = wireStart, start != pin else {
            wireStart = wireStart == pin ? nil : pin
            return false
        }
        wireStart = nil
        let startIsOutput = project.pin(start)?.direction == .output
        let (from, to) = startIsOutput ? (start, pin) : (pin, start)
        do {
            try project.connect(from: from, to: to)
            return true
        } catch {
            return false
        }
    }

    /// Removes the wire into an input pin, if there is one.
    public func disconnect(_ pin: PinRef, in project: inout ProjectFile) {
        if let edge = project.edge(into: pin) { project.removeEdge(edge) }
    }

    // MARK: Keyboard

    /// Tab and Shift-Tab: the next or previous card, in the order they were added, becomes the selection.
    public func selectNext(in project: ProjectFile, backwards: Bool = false) {
        let ids = project.nodes.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { selection.contains($0) }
        let next = current.map { (backwards ? $0 - 1 + ids.count : $0 + 1) % ids.count } ?? (backwards ? ids.count - 1 : 0)
        selection = [ids[next]]
        selectedEdge = nil
    }

    /// Arrow keys: the selected cards move one grid step (24 points).
    public func nudgeSelection(dx: Double, dy: Double, in project: inout ProjectFile) {
        guard !selection.isEmpty else { return }
        project.moveNodes(selection, byX: dx * 24, y: dy * 24)
    }

    /// Space: the selected cards flip between their pages.
    public func flipSelection() {
        for node in selection { flip(node) }
    }

    // MARK: Adding and zooming

    /// Adds a node at `position` (a card's top-left), or near the centre of the view, offset so
    /// repeated adds don't stack, and selects it.
    @discardableResult
    public func addNode(_ kind: NodeKind, at position: CanvasPoint? = nil, in project: inout ProjectFile) -> NodeID {
        var position = position ?? centrePosition
        while project.nodes.contains(where: { $0.position == position }) {
            position.x += 24
            position.y += 24
        }
        let id = project.addNode(kind, at: position)
        selection = [id]
        selectedEdge = nil
        return id
    }

    // MARK: Custom nodes

    /// Whether Group Selection would work on what's selected.
    public func canGroupSelection(in project: ProjectFile) -> Bool {
        project.canGroup(selection)
    }

    /// Whether anything selected is a custom node to ungroup.
    public func canUngroupSelection(in project: ProjectFile) -> Bool {
        selection.contains { project.node($0)?.kind == .custom }
    }

    /// Group Selection: the selected nodes become one custom node, which ends up selected.
    public func groupSelection(in project: inout ProjectFile) {
        guard let custom = project.groupNodes(selection) else { return }
        selection = [custom]
        selectedEdge = nil
    }

    public func canMakeFeedbackGroup(in project: ProjectFile) -> Bool {
        project.canMakeFeedbackGroup(selection)
    }

    /// Make Feedback Group: the selected chain becomes a custom node with a feedback loop around it.
    public func makeFeedbackGroup(in project: inout ProjectFile) {
        guard let custom = project.makeFeedbackGroup(selection) else { return }
        selection = [custom]
        selectedEdge = nil
    }

    /// Ungroup: every selected custom node gives its nodes back, and those end up selected.
    public func ungroupSelection(in project: inout ProjectFile) {
        var restored: Set<NodeID> = []
        for id in selection where project.node(id)?.kind == .custom {
            restored.formUnion(project.ungroup(id))
        }
        guard !restored.isEmpty else { return }
        selection = restored
        selectedEdge = nil
    }

    /// Adds a custom node from one of the document's definitions near the centre of the view.
    public func addCustomNode(_ definition: UUID, at position: CanvasPoint? = nil, in project: inout ProjectFile) {
        guard let id = project.addCustomNode(definition, at: position ?? centrePosition) else { return }
        selection = [id]
        selectedEdge = nil
    }

    /// Adds a custom node from a `.bakenode` (the library, a file, a drop) at `position`, or near the
    /// centre of the view: its definition joins the document unless it's already there.
    public func addCustomNode(from file: CustomNodeFile, at position: CanvasPoint? = nil, in project: inout ProjectFile) {
        let definition = project.importCustomNode(file)
        guard let id = project.addCustomNode(definition, at: position ?? centrePosition) else { return }
        selection = [id]
        selectedEdge = nil
    }

    /// Where a card added from a menu goes: its top-left a little up and left of the view's centre.
    public var centrePosition: CanvasPoint {
        cardPosition(atView: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// Where a card goes to sit centred on a point of the view (a double-click, for one).
    public func cardPosition(atView point: CGPoint) -> CanvasPoint {
        let world = viewport.toWorld(point)
        return CanvasPoint(x: Double(world.x - NodeLayout.width / 2).rounded(), y: Double(world.y - 60).rounded())
    }

    public func zoom(by factor: CGFloat) {
        viewport.zoom(by: factor, around: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    public func actualSize() {
        zoom(by: 1 / viewport.scale)
    }
}
