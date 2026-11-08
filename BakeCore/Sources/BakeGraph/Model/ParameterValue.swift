/// A stored parameter value. Encoded as `{"number": 2}`, `{"choice": "sine"}`, or `{"text": "kick"}`.
public enum ParameterValue: Hashable, Codable, Sendable {
    case number(Double)
    case choice(String)
    case text(String)

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var textValue: String? {
        if case .text(let value) = self { value } else { nil }
    }

    private enum CodingKeys: String, CodingKey {
        case number, choice, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .choice) {
            self = .choice(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(value)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a number, choice, or text parameter value."
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let value): try container.encode(value, forKey: .number)
        case .choice(let value): try container.encode(value, forKey: .choice)
        case .text(let value): try container.encode(value, forKey: .text)
        }
    }
}
