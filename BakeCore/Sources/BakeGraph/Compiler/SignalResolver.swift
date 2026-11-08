/// What the compiler needs to know about a source file. Supplied by the caller; the compiler never reads files.
public struct AssetInfo: Hashable, Sendable {
    public var frameCount: Int
    public var channelCount: Int
    public var sampleRate: Double

    public init(frameCount: Int, channelCount: Int, sampleRate: Double) {
        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}

/// The size of the signal a node renders, at the project sample rate.
public struct SignalShape: Hashable, Sendable {
    public let frames: Int
    public let channels: Int

    public init(frames: Int, channels: Int) {
        self.frames = frames
        self.channels = channels
    }

    /// Floats needed to hold the whole signal.
    public var sampleCount: Int { frames * channels }
}

/// Works out how many frames and channels each scheduled node renders, and each of its outputs
/// carries (an output may be mono while its node is not).
enum SignalResolver {
    static func generatedShape(frameSize: ParameterValue?, count: ParameterValue?) -> SignalShape? {
        guard case .choice(let frameSizeChoice)? = frameSize,
              let frameSize = Int(frameSizeChoice), frameSize > 0,
              let rawCount = count?.numberValue, rawCount.isFinite else { return nil }
        let roundedCount = rawCount.rounded()
        guard roundedCount > 0, roundedCount < Double(Int.max) else { return nil }
        let (frames, overflow) = frameSize.multipliedReportingOverflow(by: Int(roundedCount))
        guard !overflow, frames > 0 else { return nil }
        return SignalShape(frames: frames, channels: 1)
    }

    static func resolve(
        order: [NodeID], project: ProjectFile, assets: [AssetID: AssetInfo]
    ) -> (shapes: [NodeID: SignalShape], outputShapes: [PinRef: SignalShape], errors: [CompileError]) {
        let nodes = Dictionary(project.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var shapes: [NodeID: SignalShape] = [:]
        var outputShapes: [PinRef: SignalShape] = [:]
        var errors: [CompileError] = []

        func upstreamShape(of node: NodeID, pin: PinID) -> SignalShape? {
            let target = PinRef(node: node, pin: pin)
            return project.edges.first { $0.to == target }.flatMap { outputShapes[$0.from] }
        }

        /// Applies the node's channel rule, then sizes each output.
        func settle(_ id: NodeID, _ node: Node, _ resolved: SignalShape) {
            var shape = resolved
            let parameters = NodeCatalog.resolvedParameters(of: node)
            switch NodeCatalog.definition(for: node.kind).channelRule {
            case .fromLength:
                break
            case .parameter(let parameter):
                if case .choice(let choice)? = parameters[parameter], let channels = Int(choice) {
                    shape = SignalShape(frames: shape.frames, channels: channels)
                }
            case .fixed(let channels):
                shape = SignalShape(frames: shape.frames, channels: channels)
            }
            shapes[id] = shape
            for pin in NodeCatalog.pins(of: node) where pin.direction == .output {
                outputShapes[PinRef(node: id, pin: pin.id)] = pin.channels == .mono
                    ? SignalShape(frames: shape.frames, channels: 1) : shape
            }
        }

        // Forward pass: everything except control generators, whose length depends on their consumers.
        for id in order {
            guard let node = nodes[id] else { continue }
            let parameters = NodeCatalog.resolvedParameters(of: node)
            let rule = NodeCatalog.definition(for: node.kind).lengthRule.effective(for: parameters)
            switch rule {
            case .asset:
                guard let assetID = node.assetID, let info = assets[assetID],
                      info.sampleRate > 0, info.channelCount > 0 else {
                    errors.append(.unresolvableAsset(id))
                    continue
                }
                let start = parameters["cropStart"]?.numberValue ?? 0
                let end = parameters["cropEnd"]?.numberValue ?? 1
                let loops = Int((parameters["loopCount"]?.numberValue ?? 1).rounded())
                let projectFrames = Double(info.frameCount) * project.settings.sampleRate / info.sampleRate
                let frames = Int((projectFrames * (end - start)).rounded()) * loops
                guard frames > 0 else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, SignalShape(frames: frames, channels: info.channelCount))

            case .sameAsInput(let pin):
                // No upstream shape means an upstream error was already reported.
                if let input = upstreamShape(of: id, pin: pin) {
                    settle(id, node, input)
                }

            case .scaledInput(let pin, let parameter):
                guard let input = upstreamShape(of: id, pin: pin) else { continue }
                let ratio = parameters[parameter]?.numberValue ?? 1
                let frames = Int((Double(input.frames) * ratio).rounded())
                guard frames > 0 else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, SignalShape(frames: frames, channels: input.channels))

            case .looped(let pin):
                guard let input = upstreamShape(of: id, pin: pin) else { continue }
                let frames = LooperPlan.frames(inputFrames: input.frames, parameters: parameters, sampleRate: project.settings.sampleRate)
                guard frames > 0 else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, SignalShape(frames: frames, channels: input.channels))

            case .adjusted(let pin):
                guard let input = upstreamShape(of: id, pin: pin) else { continue }
                let plan = AdjustedPlan.frames(parameters, sampleRate: project.settings.sampleRate)
                guard plan.kept(of: input.frames) > 0 else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, SignalShape(frames: plan.output(of: input.frames), channels: input.channels))

            case .extendedInput(let pin, let parameter):
                guard let input = upstreamShape(of: id, pin: pin) else { continue }
                let seconds = parameters[parameter]?.numberValue ?? 0
                let frames = input.frames + Int((seconds * project.settings.sampleRate).rounded())
                settle(id, node, SignalShape(frames: frames, channels: input.channels))

            case .convolved(let inputPin, let impulsePin):
                guard let input = upstreamShape(of: id, pin: inputPin) else { continue }
                let impulseTarget = PinRef(node: id, pin: impulsePin)
                let impulseIsWired = project.edges.contains { $0.to == impulseTarget }
                var impulse: SignalShape?
                if impulseIsWired {
                    // Wired but unresolved means an upstream error was already reported.
                    guard let wired = upstreamShape(of: id, pin: impulsePin) else { continue }
                    impulse = wired
                }
                settle(id, node, ConvolverPlan.shape(input: input, impulse: impulse, parameters: parameters, sampleRate: project.settings.sampleRate))

            case .longestInput, .longestInputPlus:
                let inputs = NodeCatalog.pins(of: node)
                    .filter { $0.direction == .input && $0.signal == .audio }
                    .compactMap { upstreamShape(of: id, pin: $0.id) }
                // None resolved: either nothing is wired (the scheduler reports it) or an upstream error was.
                guard let frames = inputs.map(\.frames).max(), let channels = inputs.map(\.channels).max() else { continue }
                var extra = 0
                if case .longestInputPlus(let parameter) = rule {
                    extra = Int(((parameters[parameter]?.numberValue ?? 0) * 0.001 * project.settings.sampleRate).rounded())
                }
                settle(id, node, SignalShape(frames: frames + extra, channels: channels))

            case .joined(let gap, let crossfade):
                let inputs = NodeCatalog.pins(of: node)
                    .filter { $0.direction == .input && $0.signal == .audio }
                    .compactMap { upstreamShape(of: id, pin: $0.id) }
                guard let channels = inputs.map(\.channels).max() else { continue }
                let plan = JoinPlan(
                    lengths: inputs.map(\.frames), parameters: parameters, gap: gap, crossfade: crossfade,
                    sampleRate: project.settings.sampleRate
                )
                settle(id, node, SignalShape(frames: max(1, plan.total), channels: channels))

            case .followsConsumers:
                break

            case .seconds(let parameter):
                let frames = Int(((parameters[parameter]?.numberValue ?? 0) * project.settings.sampleRate).rounded())
                guard frames > 0 else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, SignalShape(frames: frames, channels: 1))

            case .byChoice:
                // `effective(for:)` never returns `byChoice`.
                errors.append(.invalidLength(id))

            case .generated(let frameSizeParameter, let countParameter):
                guard let shape = generatedShape(frameSize: parameters[frameSizeParameter], count: parameters[countParameter]) else {
                    errors.append(.invalidLength(id))
                    continue
                }
                settle(id, node, shape)
            }
        }

        // Reverse pass: a control generator spans the longest node it feeds.
        // Consumers come later in the order, so walking backwards resolves them first.
        for id in order.reversed() {
            guard let node = nodes[id],
                  case .followsConsumers = NodeCatalog.definition(for: node.kind).lengthRule
                      .effective(for: NodeCatalog.resolvedParameters(of: node)) else { continue }
            let spans = project.edges.filter { $0.from.node == id }.compactMap { shapes[$0.to.node]?.frames }
            guard let frames = spans.max(), frames > 0 else {
                errors.append(.invalidLength(id))
                continue
            }
            settle(id, node, SignalShape(frames: frames, channels: 1))
        }
        return (shapes, outputShapes, errors)
    }
}
