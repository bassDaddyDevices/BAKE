import BakeGraph
import SwiftUI

extension ProjectFile {
    /// The project after `change`, or nil if `change` left it equal.
    public func applying(_ change: (inout ProjectFile) -> Void) -> ProjectFile? {
        var edited = self
        change(&edited)
        return edited == self ? nil : edited
    }
}

extension Binding where Value == ProjectFile {
    /// Applies `change` to the document. SwiftUI records one undo step per `FileDocument` write,
    /// so this writes once, and not at all when nothing changed.
    public func edit(_ change: (inout ProjectFile) -> Void) {
        if let edited = wrappedValue.applying(change) {
            wrappedValue = edited
        }
    }
}
