import Foundation

/// Server-validated puzzle description (no executable code). Matches backend JSON schema.
struct PuzzleSpec: Codable, Equatable {
    let filledCellIndices: [Int]
    let hueBase: Double
    let hueOffset: Double
    var lockRatio: Double?

    enum CodingKeys: String, CodingKey {
        case filledCellIndices
        case hueBase
        case hueOffset
        case lockRatio
    }
}

struct AIPuzzleAPIResponse: Codable {
    let puzzle: PuzzleSpec
    let remainingQuota: Int?
    let tier: String?
}

struct AIPuzzleAPIErrorBody: Codable {
    let error: String?
    let message: String?
}
