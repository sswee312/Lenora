import Foundation

struct ImageGenerateParams: Encodable, Sendable, Equatable {
    let prompt: String
    let aspectRatio: String?
    let count: Int?
    let seed: Int?
}

enum ImageEditParams: Encodable, Sendable, Equatable {
    case fill(aspectRatio: String)
    case replace(from: String, to: String)
    case remove(prompt: String)
    case recolor(prompt: String, color: String)
    case backgroundReplace(prompt: String?)
    case restore

    static let operations = ["fill", "replace", "remove", "recolor", "backgroundReplace", "restore"]

    var op: String {
        switch self {
        case .fill: "fill"
        case .replace: "replace"
        case .remove: "remove"
        case .recolor: "recolor"
        case .backgroundReplace: "backgroundReplace"
        case .restore: "restore"
        }
    }

    private enum CodingKeys: String, CodingKey { case op, aspectRatio, from, to, prompt, color }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op, forKey: .op)
        switch self {
        case .fill(let aspectRatio): try c.encode(aspectRatio, forKey: .aspectRatio)
        case .replace(let from, let to): try c.encode(from, forKey: .from); try c.encode(to, forKey: .to)
        case .remove(let prompt): try c.encode(prompt, forKey: .prompt)
        case .recolor(let prompt, let color): try c.encode(prompt, forKey: .prompt); try c.encode(color, forKey: .color)
        case .backgroundReplace(let prompt): try c.encodeIfPresent(prompt, forKey: .prompt)
        case .restore: break
        }
    }
}

struct VideoGenerateParams: Encodable, Sendable, Equatable {
    let prompt: String
    let duration: Int
    let resolution: String?
    let aspectRatio: String?
    let generateAudio: Bool?
}

struct VideoReframeParams: Encodable, Sendable, Equatable {
    let aspectRatio: String
}
