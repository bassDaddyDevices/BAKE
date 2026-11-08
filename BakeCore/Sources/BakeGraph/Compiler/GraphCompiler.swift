/// Turns an editable project into an immutable render plan.
///
/// Stages run in order and stop at the first that finds problems, reporting all of that stage's errors:
/// custom nodes flattened → structure → scheduling → signal lengths → feedback loop lengths → buffer
/// planning. Errors inside a custom node are reported on the custom node, and again on its
/// definition's own cards (`CompileFailure.inside`).
public enum GraphCompiler {
    public static func compile(
        _ project: ProjectFile, assets: [AssetID: AssetInfo] = [:]
    ) throws(CompileFailure) -> RenderPlan {
        let flat = CustomNodeFlattener.flatten(project)
        guard flat.errors.isEmpty else { throw CompileFailure(errors: flat.errors) }
        do {
            return try compileFlat(flat.project, assets: assets)
        } catch {
            var errors: [CompileError] = []
            var inside: [Int: CompileFailure.Inside] = [:]
            for found in error.errors {
                // The custom node it came from: the first node it names that was inside one.
                var instance: NodeID?
                _ = found.mappingNodes { node in
                    if instance == nil { instance = flat.origin[node] }
                    return node
                }
                if let instance, let definition = project.node(instance)?.customDefinition {
                    let there = found.mappingNodes { flat.origin[$0] == instance ? flat.inner[$0] ?? $0 : $0 }
                    inside[errors.count] = CompileFailure.Inside(instance: instance, definition: definition, error: there)
                }
                errors.append(found.mappingNodes { flat.origin[$0] ?? $0 })
            }
            throw CompileFailure(errors: errors, inside: inside)
        }
    }

    private static func compileFlat(
        _ project: ProjectFile, assets: [AssetID: AssetInfo]
    ) throws(CompileFailure) -> RenderPlan {
        let structural = StructureValidator.validate(project)
        guard structural.isEmpty else { throw CompileFailure(errors: structural) }

        let schedule = Scheduler.schedule(project)
        guard schedule.errors.isEmpty else { throw CompileFailure(errors: schedule.errors) }

        let signals = SignalResolver.resolve(order: schedule.order, project: project, assets: assets)
        guard signals.errors.isEmpty else { throw CompileFailure(errors: signals.errors) }

        // A loop renders in lockstep blocks, so every node in it must be as long as its Feedback node.
        let mismatched = schedule.loops.flatMap { loop in
            loop.members.filter { signals.shapes[$0]?.frames != signals.shapes[loop.feedback]?.frames }
        }
        let order = Dictionary(schedule.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let lengthErrors = mismatched.sorted { order[$0, default: .max] < order[$1, default: .max] }.map(CompileError.feedbackLengthMismatch)
        guard lengthErrors.isEmpty else { throw CompileFailure(errors: lengthErrors) }

        // A WAV's sizes are 32-bit: past 4 GB the file can't be written, so say so before rendering.
        let tooLarge = schedule.order.compactMap { id -> CompileError? in
            guard let node = project.node(id), node.kind.isOutput, let shape = signals.shapes[id] else { return nil }
            let bytes = WAVLimit.bytes(frames: shape.frames, channels: shape.channels, bitDepth: NodeCatalog.resolvedParameters(of: node)["bitDepth"])
            return bytes > WAVLimit.maximumBytes ? .outputTooLarge(id, bytes: bytes) : nil
        }
        guard tooLarge.isEmpty else { throw CompileFailure(errors: tooLarge) }

        return BufferPlanner.plan(
            order: schedule.order, loops: schedule.loops, shapes: signals.shapes, outputShapes: signals.outputShapes, project: project
        )
    }
}

/// How big a baked WAV gets, against the 4 GB its 32-bit RIFF sizes allow.
public enum WAVLimit {
    /// The largest a RIFF/WAVE file can be, less room for its header and the patch BAKE embeds.
    public static let maximumBytes = Int(UInt32.max) - 16 * 1_024 * 1_024

    /// A bake's audio data: 2, 3 or 4 bytes a sample for 16, 24 or 32-bit float (Previews are 32-bit float).
    public static func bytes(frames: Int, channels: Int, bitDepth: ParameterValue?) -> Int {
        let width = switch bitDepth {
        case .choice("16")?: 2
        case .choice("24")?: 3
        default: 4
        }
        let samples = frames.multipliedReportingOverflow(by: channels)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: width)
        return samples.overflow || bytes.overflow ? .max : bytes.partialValue
    }
}
