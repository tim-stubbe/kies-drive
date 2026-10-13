import Foundation
import CoreLocation

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

/// Converts MapKit's compact, sometimes symbol-heavy instructions into text
/// that a German navigation voice can pronounce naturally.
enum NavigationSpeechFormatter {
    static func spokenText(_ instruction: String, distance: CLLocationDistance? = nil) -> String {
        var text = instruction
            .replacingOccurrences(of: "&", with: " und ")
            .replacingOccurrences(of: "/", with: ", ")
            .replacingOccurrences(of: "→", with: " ")
            .replacingOccurrences(of: "↗", with: " ")
            .replacingOccurrences(of: "↖", with: " ")
            .replacingOccurrences(of: "←", with: " ")

        text = replacing(#"(?i)\bStr\."#, in: text, with: "Straße")
        text = replacing(#"\s+"#, in: text, with: " ")
        text = replacing(#"\s*[,;:]\s*"#, in: text, with: ", ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        guard !text.isEmpty else { return "Bitte der Route folgen." }
        let maneuver = text.first?.isUppercase == true
            ? text
            : text.prefix(1).uppercased() + String(text.dropFirst())

        guard let distance else { return sentence(maneuver) }
        if distance <= 35 { return sentence("Jetzt, \(maneuver)") }
        let rounded = max(50, Int((distance / 50).rounded()) * 50)
        return sentence("In \(rounded) Metern, \(maneuver)")
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        return regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func sentence(_ value: String) -> String {
        value.last.map { ".!?".contains($0) } == true ? value : value + "."
    }
}

enum NavigationAnnouncementStage: Int, Hashable, CaseIterable {
    case early
    case prepare
    case now

    static func stage(distance: CLLocationDistance, speedKmh: Double) -> Self? {
        guard distance.isFinite, distance >= 0 else { return nil }
        if distance <= 45 { return .now }
        let prepareDistance: CLLocationDistance = speedKmh >= 80 ? 350 : 220
        if distance <= prepareDistance { return .prepare }
        let earlyDistance: CLLocationDistance = speedKmh >= 80 ? 900 : 500
        if distance <= earlyDistance { return .early }
        return nil
    }
}

/// Conservative acceptance rules for live navigation fixes. Core Location can
/// briefly report cached or wildly displaced positions after tunnels, pauses
/// and app resumes; those must not advance maneuvers or trigger rerouting.
enum NavigationLocationPolicy {
    static func accepts(_ candidate: CLLocation, after previous: CLLocation?, now: Date = Date()) -> Bool {
        guard candidate.horizontalAccuracy >= 0, candidate.horizontalAccuracy <= 100,
              candidate.timestamp.timeIntervalSince(now) <= 5,
              now.timeIntervalSince(candidate.timestamp) <= 20 else { return false }
        guard let previous else { return true }
        let elapsed = candidate.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return false }
        let accuracyAllowance = max(0, candidate.horizontalAccuracy) + max(0, previous.horizontalAccuracy)
        // 80 m/s is deliberately above realistic road speed. The fixed floor
        // tolerates coarse first fixes without accepting kilometre-scale jumps.
        let plausibleDistance = max(350, elapsed * 80 + accuracyAllowance)
        return candidate.distance(from: previous) <= plausibleDistance
    }
}

enum NavigationArrivalPolicy {
    static let requiredConsecutiveFixes = 3

    static func isArrivalFix(_ location: CLLocation, destination: CLLocationCoordinate2D) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return false }
        let speed = location.speed < 0 ? 0 : location.speed
        guard speed <= 8.33 else { return false } // below roughly 30 km/h
        let radius = max(35, location.horizontalAccuracy * 1.5)
        return location.distance(from: CLLocation(latitude: destination.latitude,
                                                  longitude: destination.longitude)) <= radius
    }
}

struct NavigationStepMetric: Equatable {
    let distanceFromRoute: CLLocationDistance
    let remainingOnStep: CLLocationDistance
}

/// Advances through route steps in order. A geometrically close future step
/// (parallel carriageway, bridge or cloverleaf ramp) is not enough to skip
/// ahead; normal advancement is allowed only at the current step's end.
enum NavigationStepSelectionPolicy {
    static func selectedIndex(current: Int, metrics: [NavigationStepMetric],
                              transitionRadius: CLLocationDistance) -> Int {
        guard metrics.indices.contains(current) else { return 0 }
        let radius = min(25, max(8, transitionRadius))

        // A large discontinuity is the explicit recovery path after a tunnel,
        // long pause or sparse background update. Recovery only moves forward.
        if metrics[current].distanceFromRoute > 250,
           let recovered = metrics.indices.dropFirst(current).min(by: {
               metrics[$0].distanceFromRoute < metrics[$1].distanceFromRoute
           }), metrics[recovered].distanceFromRoute + 80 < metrics[current].distanceFromRoute {
            return recovered
        }

        var selected = current
        while metrics.indices.contains(selected + 1) {
            let active = metrics[selected]
            let next = metrics[selected + 1]
            let reachedJunction = active.remainingOnStep <= radius && next.distanceFromRoute <= radius * 1.5
            let clearlyPastStep = active.distanceFromRoute > 60 &&
                next.distanceFromRoute + 30 < active.distanceFromRoute && next.distanceFromRoute <= 45
            guard reachedJunction || clearlyPastStep else { break }
            selected += 1
        }
        return selected
    }
}
