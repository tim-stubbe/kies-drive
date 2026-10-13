import Foundation

struct NavigationManeuverPresentation: Equatable {
    enum Direction: Equatable {
        case straight, slightRight, right, sharpRight, slightLeft, left, sharpLeft, uTurn, roundabout

        var symbolName: String {
            switch self {
            case .straight: "arrow.up"
            case .slightRight: "arrow.up.right"
            case .right: "arrow.turn.up.right"
            case .sharpRight: "arrow.turn.up.right"
            case .slightLeft: "arrow.up.left"
            case .left: "arrow.turn.up.left"
            case .sharpLeft: "arrow.turn.up.left"
            case .uTurn: "arrow.uturn.down"
            case .roundabout: "arrow.trianglehead.2.clockwise.rotate.90"
            }
        }
    }

    let instruction: String
    let exitLabel: String?
    let roadLabel: String?
    let destinationLabel: String?
    let direction: Direction

    init(_ instruction: String) {
        self.instruction = instruction.isEmpty ? "Route folgen" : instruction
        let lower = instruction.lowercased()
        if lower.contains("kreisverkehr") || lower.contains("roundabout") { direction = .roundabout }
        else if lower.contains("wenden") || lower.contains("u-turn") { direction = .uTurn }
        else if lower.contains("scharf rechts") { direction = .sharpRight }
        else if lower.contains("leicht rechts") || lower.contains("rechts halten") { direction = .slightRight }
        else if lower.contains("rechts") || lower.contains("ausfahrt") || lower.contains("exit") { direction = .right }
        else if lower.contains("scharf links") { direction = .sharpLeft }
        else if lower.contains("leicht links") || lower.contains("links halten") { direction = .slightLeft }
        else if lower.contains("links") { direction = .left }
        else { direction = .straight }

        let pattern = #"(?i)(?:Ausfahrt|Exit)\s+([0-9]+[a-z]?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
           let range = Range(match.range(at: 1), in: instruction) {
            exitLabel = "Ausfahrt \(instruction[range])"
        } else {
            exitLabel = nil
        }

        let roadPattern = #"(?i)\b(?:A|B|L|K)\s?[0-9]{1,4}[a-z]?\b"#
        if let regex = try? NSRegularExpression(pattern: roadPattern),
           let match = regex.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
           let range = Range(match.range, in: instruction) {
            roadLabel = instruction[range].replacingOccurrences(of: " ", with: "").uppercased()
        } else {
            roadLabel = nil
        }

        let destinationPattern = #"(?i)\b(?:Richtung|toward|towards)\s+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: destinationPattern),
           let match = regex.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
           let range = Range(match.range(at: 1), in: instruction) {
            let value = instruction[range].trimmingCharacters(in: .whitespacesAndNewlines)
            destinationLabel = value.isEmpty ? nil : value
        } else {
            destinationLabel = nil
        }
    }
}
