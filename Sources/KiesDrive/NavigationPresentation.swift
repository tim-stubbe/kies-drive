import Foundation
import CoreLocation
import MapKit

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

        let roadPattern = #"(?i)\b(?:A|B|E|L|K)\s?[0-9]{1,4}[a-z]?\b"#
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
            .replacingOccurrences(of: "•", with: ", ")
            .replacingOccurrences(of: "·", with: ", ")
            .replacingOccurrences(of: "–", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "(", with: ", ")
            .replacingOccurrences(of: ")", with: " ")

        text = replacing(#"(?i)\bStr\."#, in: text, with: "Straße")
        text = replacing(#"(?i)\bBAB\s*([0-9]{1,3})\b"#, in: text, with: "Autobahn $1")
        // Force a small spoken pause between road class and number. Compact
        // forms such as A66 or B40 otherwise sound like arbitrary words on
        // some installed German voices.
        text = replacing(#"(?i)\b([ABELK])\s*([0-9]{1,4})([a-z]?)\b"#,
                         in: text, with: "$1 $2$3")
        text = replacing(#"(?i)\bkm\s*/\s*h\b"#, in: text, with: "Kilometer pro Stunde")
        text = text.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.illegalCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        text = replacing(#"\s+"#, in: text, with: " ")
        text = replacing(#"\s*[,;:]\s*"#, in: text, with: ", ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        guard !text.isEmpty else { return "Bitte der Route folgen." }
        let maneuver = text.first?.isUppercase == true
            ? text
            : text.prefix(1).uppercased() + String(text.dropFirst())

        guard let distance else { return sentence(maneuver) }
        if distance <= 35 { return sentence("Jetzt, \(maneuver)") }
        return sentence("\(distancePrefix(distance)), \(maneuver)")
    }

    /// Combines two very close turns into one final cue. This prevents a
    /// second maneuver from being announced only after the driver has already
    /// committed to the wrong lane.
    static func spokenText(_ instruction: String, distance: CLLocationDistance,
                           then followingInstruction: String?,
                           followingDistance: CLLocationDistance?) -> String {
        let primary = spokenText(instruction, distance: distance)
        guard let followingInstruction, let followingDistance,
              followingDistance.isFinite, followingDistance >= 0,
              followingDistance <= 450 else { return primary }
        let following = spokenText(followingInstruction)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        guard !following.isEmpty else { return primary }
        let first = primary.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        return "\(first). Danach, \(following)."
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

    private static func distancePrefix(_ distance: CLLocationDistance) -> String {
        if distance >= 950 {
            let kilometres = ((distance / 1_000) * 2).rounded() / 2
            if kilometres == 1 { return "In einem Kilometer" }
            let value = kilometres.rounded() == kilometres
                ? String(Int(kilometres))
                : String(format: "%.1f", kilometres).replacingOccurrences(of: ".", with: ",")
            return "In \(value) Kilometern"
        }
        let rounded = max(50, Int((distance / 50).rounded()) * 50)
        return "In \(rounded) Metern"
    }
}

enum NavigationAnnouncementStage: Int, Hashable, CaseIterable {
    case early
    case prepare
    case now

    static func stage(distance: CLLocationDistance, speedKmh: Double) -> Self? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let speedMetresPerSecond = max(0, speedKmh) / 3.6
        // Time-based horizons keep exits safe at motorway speeds. Four seconds
        // for the final cue leaves enough time even when Core Location skips a
        // sample, while the caps keep city guidance from becoming premature.
        let nowDistance = min(260, max(40, speedMetresPerSecond * 4))
        if distance <= nowDistance { return .now }
        let prepareDistance = min(1_100, max(220, speedMetresPerSecond * 15))
        if distance <= prepareDistance { return .prepare }
        let earlyDistance = min(3_000, max(500, speedMetresPerSecond * 45))
        if distance <= earlyDistance { return .early }
        return nil
    }
}

enum ManeuverDiagnosticPolicy {
    static func missedFinalCue(stages: Set<NavigationAnnouncementStage>) -> Bool {
        !stages.contains(.now)
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

/// Shared plausibility rules for motion values reported by Core Location.
/// A position can be good enough to advance along a route while its speed or
/// course is still unusable (for example directly after leaving a tunnel).
/// Consumers must retain their last useful camera heading instead of turning
/// an invalid course into north.
enum NavigationMotionPolicy {
    static func reliableSpeed(speedMetresPerSecond: Double, speedAccuracy: Double,
                              horizontalAccuracy: Double) -> Double? {
        guard speedMetresPerSecond.isFinite, speedMetresPerSecond >= 0,
              speedMetresPerSecond <= 80,
              horizontalAccuracy >= 0, horizontalAccuracy <= 65 else { return nil }
        // A negative accuracy means that this OS/location source does not
        // provide the field. Otherwise reject fixes whose uncertainty is too
        // large to drive warnings or timing decisions.
        guard speedAccuracy < 0 || speedAccuracy <= 5 else { return nil }
        return speedMetresPerSecond
    }

    static func reliableCourse(courseDegrees: Double, courseAccuracy: Double,
                               speedMetresPerSecond: Double) -> Double? {
        guard courseDegrees.isFinite, courseDegrees >= 0, courseDegrees < 360,
              speedMetresPerSecond.isFinite, speedMetresPerSecond >= 2.5,
              courseAccuracy < 0 || courseAccuracy <= 35 else { return nil }
        return courseDegrees
    }

    static func reliableSpeed(for location: CLLocation) -> Double? {
        reliableSpeed(speedMetresPerSecond: location.speed,
                      speedAccuracy: location.speedAccuracy,
                      horizontalAccuracy: location.horizontalAccuracy)
    }

    static func reliableCourse(for location: CLLocation) -> Double? {
        reliableCourse(courseDegrees: location.course,
                       courseAccuracy: location.courseAccuracy,
                       speedMetresPerSecond: reliableSpeed(for: location) ?? -1)
    }
}

/// Keeps announcement timing stable when Core Location temporarily publishes
/// an invalid speed (common after tunnels, background resumes and CarPlay
/// reconnects). A short-lived last trustworthy value is safer than suddenly
/// shrinking a motorway warning horizon to the stationary fallback.
enum NavigationGuidanceSpeedPolicy {
    static let retention: TimeInterval = 20
    static let fallbackMetresPerSecond = 13.9 // roughly 50 km/h

    static func effective(current: Double?, previous: Double?, previousAt: Date?,
                          now: Date) -> Double {
        if let current { return current }
        if let previous, let previousAt,
           now.timeIntervalSince(previousAt) >= 0,
           now.timeIntervalSince(previousAt) <= retention {
            return previous
        }
        return fallbackMetresPerSecond
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
    /// Prevents a crossing or parallel piece of the same long route from
    /// snapping guidance hours ahead after one inaccurate tunnel fix.
    private static let maximumRecoveryStepAdvance = 16

    static func selectedIndex(current: Int, metrics: [NavigationStepMetric],
                              transitionRadius: CLLocationDistance,
                              allowsFullRecovery: Bool = false) -> Int {
        guard metrics.indices.contains(current) else { return 0 }
        let radius = min(25, max(8, transitionRadius))

        // Only the first fix of a restored offline route may search the whole
        // remaining journey. Prefer the earliest plausible road segment over
        // a microscopically closer later crossing, so loops and cloverleafs do
        // not skip required sections. Normal live updates keep the tight
        // forward window below.
        if allowsFullRecovery, metrics[current].distanceFromRoute > 250 {
            if let earliestPlausible = metrics.indices.dropFirst(current).first(where: {
                metrics[$0].distanceFromRoute <= max(45, radius * 1.5)
            }) {
                return earliestPlausible
            }
            if let nearest = metrics.indices.dropFirst(current).min(by: {
                metrics[$0].distanceFromRoute < metrics[$1].distanceFromRoute
            }), metrics[nearest].distanceFromRoute + 250 < metrics[current].distanceFromRoute {
                return nearest
            }
        }

        // A large discontinuity is the explicit recovery path after a tunnel,
        // long pause or sparse background update. Recovery only moves forward.
        let recoveryEnd = min(metrics.count, current + maximumRecoveryStepAdvance + 1)
        if metrics[current].distanceFromRoute > 250,
           let recovered = (current..<recoveryEnd).min(by: {
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
enum NavigationEstimatePolicy {
    /// Conservative time to the next maneuver. GPS speed is useful when
    /// moving, while a 50 km/h fallback avoids absurd zero-second CarPlay ETAs.
    static func timeToManeuver(distanceMetres: Double, speedMetresPerSecond: Double) -> TimeInterval {
        guard distanceMetres > 0 else { return 0 }
        let effectiveSpeed = speedMetresPerSecond > 2 ? min(speedMetresPerSecond, 55) : 13.9
        return max(1, distanceMetres / effectiveSpeed)
    }
}

enum NavigationDeviationPolicy {
    static func threshold(horizontalAccuracy: Double, speedMetresPerSecond: Double) -> Double {
        max(100, horizontalAccuracy * 3, min(220, max(speedMetresPerSecond, 0) * 4))
    }

    static func shouldAccumulate(distanceFromRoute: Double, previousDistance: Double?,
                                 horizontalAccuracy: Double, speedMetresPerSecond: Double) -> Bool {
        guard horizontalAccuracy >= 0, horizontalAccuracy <= 65, speedMetresPerSecond >= 2.5 else { return false }
        guard distanceFromRoute > threshold(horizontalAccuracy: horizontalAccuracy,
                                            speedMetresPerSecond: speedMetresPerSecond) else { return false }
        if let previousDistance, distanceFromRoute + 30 < previousDistance { return false }
        return true
    }

    static func confirmationDuration(speedMetresPerSecond: Double) -> TimeInterval {
        speedMetresPerSecond > 22 ? 8 : 12
    }
}

enum OfflineRouteRecoveryPolicy {
    static let retryInterval: TimeInterval = 90

    static func shouldAttempt(lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }
}

enum OfflineRouteCachePolicy {
    /// New caches are tied to a geographic destination, not merely a place
    /// label that may occur in several cities. Name-only matching remains as
    /// a compatibility path for caches from older app versions.
    static func matches(cacheName: String, cacheCoordinate: CLLocationCoordinate2D?,
                        destinationName: String, destinationCoordinate: CLLocationCoordinate2D?) -> Bool {
        if let cacheCoordinate, let destinationCoordinate {
            return CLLocation(latitude: cacheCoordinate.latitude, longitude: cacheCoordinate.longitude)
                .distance(from: CLLocation(latitude: destinationCoordinate.latitude,
                                           longitude: destinationCoordinate.longitude)) <= 250
        }
        return cacheName.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                destinationName.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
    }
}

enum RouteSearchPolicy {
    /// Keeps a tiny tolerance for GPS jitter around the current route point,
    /// but never sends the driver materially backwards for an added stop.
    static func isAhead(candidateIndex: Int, currentIndex: Int, routePointCount: Int) -> Bool {
        guard routePointCount > 0 else { return false }
        let tolerance = max(2, routePointCount / 50)
        return candidateIndex >= max(0, currentIndex - tolerance)
    }

    static func isAhead(candidateProgress: Double, currentProgress: Double) -> Bool {
        candidateProgress >= max(0, currentProgress - 0.02)
    }
}

struct OfflineGuidanceStep {
    let instruction: String
    let distance: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]
}

struct OfflineGuidanceProgress: Equatable {
    let currentStepIndex: Int
    let maneuverStepIndex: Int
    let instruction: String
    let distanceToManeuver: CLLocationDistance
    let remainingDistance: CLLocationDistance
    let upcomingInstructions: [String]
    let followingManeuverDistance: CLLocationDistance?
}

enum OfflineGuidanceEngine {
    static func progress(at coordinate: CLLocationCoordinate2D, currentIndex: Int,
                         steps: [OfflineGuidanceStep],
                         transitionRadius: CLLocationDistance,
                         allowsFullRecovery: Bool = false) -> OfflineGuidanceProgress? {
        guard !steps.isEmpty else { return nil }
        let metrics = steps.map {
            NavigationStepMetric(distanceFromRoute: distance(from: coordinate, to: $0.coordinates),
                                 remainingOnStep: remaining(from: coordinate, on: $0.coordinates))
        }
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: min(max(0, currentIndex), steps.count - 1), metrics: metrics,
            transitionRadius: transitionRadius,
            allowsFullRecovery: allowsFullRecovery
        )
        let routeRemaining = max(0, metrics[selected].remainingOnStep +
            steps.dropFirst(selected + 1).reduce(0) { $0 + $1.distance })
        guard let maneuver = steps.indices.dropFirst(selected + 1).first(where: {
            !steps[$0].instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return .init(currentStepIndex: selected, maneuverStepIndex: selected,
                         instruction: "Dem Straßenverlauf bis zum Ziel folgen",
                         distanceToManeuver: routeRemaining, remainingDistance: routeRemaining,
                         upcomingInstructions: ["Dem Straßenverlauf bis zum Ziel folgen"],
                         followingManeuverDistance: nil)
        }
        let distanceToManeuver = metrics[selected].remainingOnStep +
            steps[(selected + 1)..<maneuver].reduce(0) { $0 + $1.distance }
        let upcoming = steps[maneuver...].map(\.instruction).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let followingIndex = steps.indices.dropFirst(maneuver + 1).first(where: {
            !steps[$0].instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        let followingDistance = followingIndex.map { index in
            steps[maneuver..<index].reduce(0) { $0 + $1.distance }
        }
        return .init(currentStepIndex: selected, maneuverStepIndex: maneuver,
                     instruction: steps[maneuver].instruction,
                     distanceToManeuver: max(0, distanceToManeuver),
                     remainingDistance: routeRemaining,
                     upcomingInstructions: Array(upcoming.prefix(5)),
                     followingManeuverDistance: followingDistance)
    }

    private static func distance(from coordinate: CLLocationCoordinate2D,
                                 to coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return .greatestFiniteMagnitude }
        let point = MKMapPoint(coordinate)
        let route = coordinates.map(MKMapPoint.init)
        return route.indices.dropLast().reduce(.greatestFiniteMagnitude) { best, index in
            min(best, segmentProjection(point, route[index], route[index + 1]).distance)
        }
    }

    private static func remaining(from coordinate: CLLocationCoordinate2D,
                                  on coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return .greatestFiniteMagnitude }
        let point = MKMapPoint(coordinate)
        let route = coordinates.map(MKMapPoint.init)
        var best = (index: 0, projection: route[0], distance: CLLocationDistance.greatestFiniteMagnitude)
        for index in route.indices.dropLast() {
            let projected = segmentProjection(point, route[index], route[index + 1])
            if projected.distance < best.distance {
                best = (index, projected.point, projected.distance)
            }
        }
        var value = best.projection.distance(to: route[best.index + 1])
        if best.index + 1 < route.count - 1 {
            for index in (best.index + 1)..<(route.count - 1) {
                value += route[index].distance(to: route[index + 1])
            }
        }
        return value
    }

    private static func segmentProjection(_ point: MKMapPoint, _ start: MKMapPoint,
                                          _ end: MKMapPoint) -> (point: MKMapPoint, distance: CLLocationDistance) {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projected = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
        return (projected, point.distance(to: projected))
    }
}
