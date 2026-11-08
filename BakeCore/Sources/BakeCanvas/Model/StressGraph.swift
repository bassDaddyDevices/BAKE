import BakeGraph

/// `rows` × 5 nodes (Audio → Filters → Distortion → Print, an LFO on cutoff) for canvas
/// performance checks from the Debug menu.
public enum StressGraph {
    public static func project(rows: Int = 20) -> ProjectFile {
        var project = ProjectFile()
        for row in 0..<rows {
            let y = Double(row) * 260
            let audio = project.addNode(.audio, at: CanvasPoint(x: 0, y: y))
            let lfo = project.addNode(.lfo, at: CanvasPoint(x: 0, y: y + 130))
            let filters = project.addNode(.filters, at: CanvasPoint(x: 320, y: y))
            let distortion = project.addNode(.distortion, at: CanvasPoint(x: 640, y: y))
            let print = project.addNode(.print, at: CanvasPoint(x: 960, y: y))
            project.setModulated("cutoff", of: filters, true)
            try? project.connect(from: PinRef(node: audio, pin: "out"), to: PinRef(node: filters, pin: "in"))
            try? project.connect(from: PinRef(node: lfo, pin: "out"), to: PinRef(node: filters, pin: "mod.cutoff"))
            try? project.connect(from: PinRef(node: filters, pin: "out"), to: PinRef(node: distortion, pin: "in"))
            try? project.connect(from: PinRef(node: distortion, pin: "out"), to: PinRef(node: print, pin: "in"))
        }
        return project
    }
}
