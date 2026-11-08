import BakeGraph
import SwiftUI
import Testing
@testable import BakeCanvas

@MainActor
struct ProjectEditingTests {
    /// Backing storage for a test binding; counts every write.
    private final class Store {
        var project = ProjectFile()
        var writes = 0
    }

    @Test func unchangedEditsReturnNil() {
        let project = ProjectFile()
        #expect(project.applying { _ in } == nil)
        #expect(project.applying { $0.addNode(.lfo, at: CanvasPoint()) }?.nodes.count == 1)
    }

    @Test func bindingEditsWriteOnlyWhenSomethingChanged() {
        let store = Store()
        let binding = Binding(get: { store.project }, set: { store.project = $0; store.writes += 1 })

        binding.edit { _ in }
        #expect(store.writes == 0)
        binding.edit { $0.addNode(.lfo, at: CanvasPoint()) }
        #expect(store.writes == 1)
        #expect(store.project.nodes.count == 1)
    }
}
