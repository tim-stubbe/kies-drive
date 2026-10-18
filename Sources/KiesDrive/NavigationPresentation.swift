import Foundation
import CoreLocation
import MapKit

final class NavigationSearchCompletionGate<Value> {
    private(set) var didComplete = false

    @discardableResult
    func complete(_ value: Value, using handler: (Value) -> Void) -> Bool {
        guard !didComplete else { return false }
        didComplete = true
        handler(value)
        return true
    }
}

enum NavigationSearchTimeoutPolicy {
    static let timeoutNanoseconds: UInt64 = 8_000_000_000
}

enum DestinationSearchCompletionPolicy {
    static func mayPublish(request: UUID, currentRequest: UUID,
                           query: String, currentText: String) -> Bool {
        request == currentRequest &&
            query == currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CarPlayAlertPresentationPolicy {
    static func titleVariants(for message: String) -> [String] {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? ["Aktion nicht möglich"] : [cleaned, "Aktion nicht möglich"]
    }
}

struct CarPlayPlannedStopAction: Equatable {
    enum Purpose: Equatable {
        case breakOnly
        case fuelOnly
        case breakAndFuel
    }

    let candidate: BreakCandidate
    let purpose: Purpose
    let afterDriving: TimeInterval?
    let afterDistanceMetres: Double?
}

enum CarPlayPlannedStopPolicy {
    /// CarPlay must remain short and glanceable. Prefer the earliest remaining
    /// stop from the currently selected scenario, combine fuel and rest at the
    /// same place, and never offer a stop that is already locked into the route.
    static func actions(plan: LongTripPlan?, existingWaypointIDs: Set<String>,
                        existingWaypointNames: Set<String>, maximum: Int = 2)
        -> [CarPlayPlannedStopAction] {
        guard maximum > 0, let result = plan?.results.first else { return [] }
        let normalizedNames = Set(existingWaypointNames.map(normalize))
        let fuelByID = Dictionary(uniqueKeysWithValues: result.fuelStops.compactMap { stop in
            stop.candidate.map { ($0.id, stop) }
        })
        var seen = Set<String>()
        var actions = result.breaks.compactMap { plannedBreak -> CarPlayPlannedStopAction? in
            guard let candidate = plannedBreak.candidate,
                  !isExisting(candidate, ids: existingWaypointIDs, names: normalizedNames),
                  seen.insert(candidate.id).inserted else { return nil }
            let fuelStop = fuelByID[candidate.id]
            return .init(candidate: candidate,
                         purpose: fuelStop == nil ? .breakOnly : .breakAndFuel,
                         afterDriving: plannedBreak.afterDriving,
                         afterDistanceMetres: fuelStop?.afterDistanceMetres)
        }
        actions += result.fuelStops.compactMap { fuelStop -> CarPlayPlannedStopAction? in
            guard let candidate = fuelStop.candidate,
                  !isExisting(candidate, ids: existingWaypointIDs, names: normalizedNames),
                  seen.insert(candidate.id).inserted else { return nil }
            return .init(candidate: candidate, purpose: .fuelOnly, afterDriving: nil,
                         afterDistanceMetres: fuelStop.afterDistanceMetres)
        }
        return Array(actions.sorted {
            ($0.candidate.timeProgress ?? $0.candidate.progress) <
                ($1.candidate.timeProgress ?? $1.candidate.progress)
        }.prefix(maximum))
    }

    private static func isExisting(_ candidate: BreakCandidate, ids: Set<String>,
                                   names: Set<String>) -> Bool {
        ids.contains(candidate.id) || names.contains(normalize(candidate.name))
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

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
        else { direction = Self.firstDirection(in: lower) }

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
            let value = Self.cleanedDestination(String(instruction[range]))
            destinationLabel = value.isEmpty ? nil : value
        } else {
            destinationLabel = nil
        }
    }

    private static func firstDirection(in text: String) -> Direction {
        if text.contains("ausfahrt links") || text.contains("exit left") { return .left }
        if text.contains("ausfahrt rechts") || text.contains("exit right") { return .right }
        let candidates: [(String, Direction, Int)] = [
            ("scharf rechts", .sharpRight, 3), ("sharp right", .sharpRight, 3),
            ("leicht rechts", .slightRight, 2), ("rechts halten", .slightRight, 2),
            ("slight right", .slightRight, 2), ("keep right", .slightRight, 2),
            ("rechts", .right, 1), ("turn right", .right, 1),
            ("scharf links", .sharpLeft, 3), ("sharp left", .sharpLeft, 3),
            ("leicht links", .slightLeft, 2), ("links halten", .slightLeft, 2),
            ("slight left", .slightLeft, 2), ("keep left", .slightLeft, 2),
            ("links", .left, 1), ("turn left", .left, 1),
            ("ausfahrt", .right, 0), ("exit", .right, 0),
        ]
        let matches = candidates.compactMap { phrase, direction, specificity
            -> (offset: Int, direction: Direction, specificity: Int)? in
            guard let range = text.range(of: phrase) else { return nil }
            return (text.distance(from: text.startIndex, to: range.lowerBound), direction, specificity)
        }
        return matches.min {
            $0.offset == $1.offset ? $0.specificity > $1.specificity : $0.offset < $1.offset
        }?.direction ?? .straight
    }

    private static func cleanedDestination(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"(?i)\s+auf\s+(?:die|der|den)?\s*(?:A|B|E|L|K)\s?[0-9]{1,4}[a-z]?(?:\s+fahren)?$"#,
            #"(?i)\s+(?:nehmen|fahren|folgen|weiterfahren|abbiegen)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            value = regex.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: ""
            )
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
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
    case final
    case now

    static func stage(distance: CLLocationDistance, speedKmh: Double) -> Self? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let speedMetresPerSecond = max(0, speedKmh) / 3.6
        // Keep the actual "Jetzt" cue close to the junction. A separate final
        // distance cue below retains the full six-second safety horizon at
        // motorway speed without saying "Jetzt" hundreds of metres early.
        let nowDistance = min(180, max(25, speedMetresPerSecond * 3))
        if distance <= nowDistance { return .now }
        let finalDistance = min(350, max(60, speedMetresPerSecond * 6))
        if distance <= finalDistance { return .final }
        let prepareDistance = min(1_100, max(220, speedMetresPerSecond * 15))
        if distance <= prepareDistance { return .prepare }
        let earlyDistance = min(3_000, max(500, speedMetresPerSecond * 45))
        if distance <= earlyDistance { return .early }
        return nil
    }
}

enum NavigationSpeechPriority: Int, Equatable {
    case status
    case maneuver
    case critical

    static func forAnnouncementStage(_ stage: NavigationAnnouncementStage) -> Self {
        stage == .now ? .critical : .maneuver
    }
}

/// Separates speech accepted by AVSpeechSynthesizer from speech that has
/// actually started. Audio-route changes can cancel a queued utterance; that
/// maneuver must remain eligible for the next location update.
enum NavigationAnnouncementDeliveryPolicy {
    static func stages(upTo stage: NavigationAnnouncementStage)
        -> Set<NavigationAnnouncementStage> {
        Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
    }

    static func shouldAttempt(_ stage: NavigationAnnouncementStage,
                              delivered: Set<NavigationAnnouncementStage>,
                              pending: Set<NavigationAnnouncementStage>) -> Bool {
        !delivered.contains(stage) && !pending.contains(stage)
    }

    /// `didStart` only proves that the audio system accepted an utterance.
    /// Bluetooth route changes, Siri and phone calls can still cancel it before
    /// the driver hears the decisive words. Commit delivery only on finish.
    static func shouldCommitDelivery(didFinish: Bool) -> Bool { didFinish }
}

enum NavigationSpeechClaimTimeoutPolicy {
    static let pendingTimeout: TimeInterval = 4
    static let activeTimeout: TimeInterval = 20

    static func isExpired(issuedAt: Date, now: Date, active: Bool) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        guard age >= 0 else { return false }
        return age >= (active ? activeTimeout : pendingTimeout)
    }
}

enum NavigationSpeechInterruptionPolicy {
    static func shouldInterrupt(active: NavigationSpeechPriority,
                                incoming: NavigationSpeechPriority) -> Bool {
        incoming.rawValue >= active.rawValue
    }

    /// Once a replacement route is committed, every queued or audible
    /// maneuver belongs to geometry that is no longer authoritative. Even a
    /// critical final cue must be cancelled instead of directing the driver
    /// onto the superseded route.
    static func shouldCancelForRouteReplacement(navigationActive: Bool,
                                                hasSpeechWork: Bool) -> Bool {
        navigationActive && hasSpeechWork
    }
}

struct NavigationInitialManeuver: Equatable {
    let instruction: String
    let distance: CLLocationDistance
    let upcomingInstructions: [String]
    let followingManeuverDistance: CLLocationDistance?
}

enum CarPlayGuidancePresentationPolicy {
    /// CarPlay maneuver objects are expensive presentation state. Rebuild
    /// them only from real route instructions; transient spoken status text
    /// such as "Route wird neu berechnet" must never become a turn card.
    static func instructions(upcoming: [String], next: String?) -> [String] {
        let cleanedUpcoming = upcoming.compactMap { value -> String? in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        if !cleanedUpcoming.isEmpty { return Array(cleanedUpcoming.prefix(3)) }
        let cleanedNext = next?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [cleanedNext.isEmpty ? "Route folgen" : cleanedNext]
    }

    /// CarPlay chooses the first variant that fits the current dashboard.
    /// Supplying only MapKit's long sentence can hide the exit number on a
    /// narrow instrument display, so progressively shorter variants retain
    /// the decisive road/exit information.
    static func variants(for instruction: String) -> [String] {
        let presentation = NavigationManeuverPresentation(instruction)
        var candidates = [presentation.instruction]
        if let exit = presentation.exitLabel, let destination = presentation.destinationLabel {
            candidates.append("\(exit), Richtung \(destination)")
        }
        if let road = presentation.roadLabel, let destination = presentation.destinationLabel {
            candidates.append("\(road), Richtung \(destination)")
        }
        if let exit = presentation.exitLabel { candidates.append(exit) }
        if let road = presentation.roadLabel { candidates.append(road) }

        var seen = Set<String>()
        return candidates.compactMap { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }
}

/// Builds the first guidance card directly from a newly committed route.
/// This is deliberately independent of the previous GPS cursor so changing a
/// destination or completing a reroute can never briefly publish or speak an
/// instruction belonging to the old route.
enum NavigationInitialManeuverPolicy {
    static func seed(steps: [(instruction: String, distance: CLLocationDistance)])
        -> NavigationInitialManeuver? {
        guard let maneuverIndex = steps.indices.first(where: {
            !steps[$0].instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        let distance = steps[..<maneuverIndex].reduce(0) { $0 + max(0, $1.distance) }
        let upcoming = steps[maneuverIndex...].compactMap { step -> String? in
            let value = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let followingIndex = steps.indices.dropFirst(maneuverIndex + 1).first(where: {
            !steps[$0].instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        let followingDistance = followingIndex.map { index in
            steps[maneuverIndex..<index].reduce(0) { $0 + max(0, $1.distance) }
        }
        return .init(
            instruction: steps[maneuverIndex].instruction,
            distance: distance,
            upcomingInstructions: Array(upcoming.prefix(5)),
            followingManeuverDistance: followingDistance
        )
    }
}

enum ManeuverDiagnosticPolicy {
    enum ClosureReason {
        case routeTransition
        case arrival
        case userStopped
    }

    static func missedFinalCue(stages: Set<NavigationAnnouncementStage>) -> Bool {
        !stages.contains(.now)
    }

    static func shouldRecordMissedFinalCue(stages: Set<NavigationAnnouncementStage>,
                                           reason: ClosureReason) -> Bool {
        guard reason != .userStopped else { return false }
        return missedFinalCue(stages: stages)
    }

    /// A sparse location update can move directly from the road before a
    /// junction onto the road after it. In that case the final cue must be
    /// recovered once instead of silently disappearing with the old step.
    /// Route replacements clear the previous key before publishing their new
    /// steps, so this applies only to a genuine in-route maneuver transition.
    static func shouldRecoverFinalCue(previousKey: String?, nextKey: String,
                                      stages: Set<NavigationAnnouncementStage>) -> Bool {
        guard let previousKey, previousKey != nextKey else { return false }
        return missedFinalCue(stages: stages)
    }
}

/// Conservative acceptance rules for live navigation fixes. Core Location can
/// briefly report cached or wildly displaced positions after tunnels, pauses
/// and app resumes; those must not advance maneuvers or trigger rerouting.
enum NavigationLocationPolicy {
    static let maximumLiveAge: TimeInterval = 20

    static func accepts(_ candidate: CLLocation, after previous: CLLocation?, now: Date = Date(),
                        maximumAge: TimeInterval = maximumLiveAge) -> Bool {
        rejectionReason(for: candidate, after: previous, now: now, maximumAge: maximumAge) == nil
    }

    static func rejectionReason(for candidate: CLLocation, after previous: CLLocation?,
                                now: Date = Date(),
                                maximumAge: TimeInterval = maximumLiveAge) -> String? {
        guard candidate.horizontalAccuracy >= 0 else { return "GPS-Genauigkeit fehlt" }
        guard candidate.horizontalAccuracy <= 100 else {
            return "GPS zu ungenau (±\(Int(candidate.horizontalAccuracy.rounded())) m)"
        }
        guard candidate.timestamp.timeIntervalSince(now) <= 5 else { return "GPS-Zeit liegt in der Zukunft" }
        guard now.timeIntervalSince(candidate.timestamp) <= maximumAge else {
            return "GPS-Messung ist veraltet"
        }
        guard let previous else { return nil }
        let elapsed = candidate.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return "GPS-Zeit ist nicht fortlaufend" }
        let accuracyAllowance = max(0, candidate.horizontalAccuracy) + max(0, previous.horizontalAccuracy)
        // 80 m/s is deliberately above realistic road speed. The fixed floor
        // tolerates coarse first fixes without accepting kilometre-scale jumps.
        let plausibleDistance = max(350, elapsed * 80 + accuracyAllowance)
        let distance = candidate.distance(from: previous)
        guard distance <= plausibleDistance else {
            return "Unplausibler GPS-Sprung (\(Int(distance.rounded())) m in \(Int(elapsed.rounded())) s)"
        }
        return nil
    }
}

/// Core Location may batch several fixes after a tunnel, a locked display or
/// a short background interval. Guidance must consume those fixes in temporal
/// order; using only the last value can jump across a junction and lose both
/// the final spoken cue and the next maneuver presentation.
enum NavigationLocationBatchPolicy {
    /// Long enough to bridge a normal tunnel or short suspension, while
    /// deliberately refusing an indefinitely cached Core Location history.
    static let maximumBufferedSampleAge: TimeInterval = 2 * 60

    static func orderedDistinct(_ locations: [CLLocation]) -> [CLLocation] {
        locations.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.timestamp == rhs.element.timestamp {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.timestamp < rhs.element.timestamp
            }
            .reduce(into: [CLLocation]()) { result, indexed in
                let candidate = indexed.element
                guard let previous = result.last else {
                    result.append(candidate)
                    return
                }
                let sameTimestamp = candidate.timestamp == previous.timestamp
                let sameCoordinate = candidate.coordinate.latitude == previous.coordinate.latitude &&
                    candidate.coordinate.longitude == previous.coordinate.longitude
                guard sameTimestamp && sameCoordinate else {
                    result.append(candidate)
                    return
                }
                // Some providers refine the final fix in place. Keep the
                // version with useful, tighter horizontal accuracy instead
                // of whichever duplicate happened to be delivered first.
                if candidate.horizontalAccuracy >= 0 &&
                    (previous.horizontalAccuracy < 0 ||
                     candidate.horizontalAccuracy < previous.horizontalAccuracy) {
                    result[result.count - 1] = candidate
                }
            }
    }
}

enum NavigationLocationAuthorizationPolicy {
    /// iOS commonly answers the first "Always" request with When-In-Use.
    /// Ask for the background upgrade only when guidance actually begins, so
    /// the prompt is relevant and locked-screen/CarPlay navigation can keep
    /// receiving fixes.
    static func shouldRequestAlways(navigationActive: Bool,
                                    hasWhenInUseAuthorization: Bool) -> Bool {
        navigationActive && hasWhenInUseAuthorization
    }

    static func requiresSystemSettings(_ authorization: CLAuthorizationStatus) -> Bool {
        authorization == .denied || authorization == .restricted
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
    let stepDistance: CLLocationDistance
    /// Difference between the car's trustworthy course and the local route
    /// segment. `nil` deliberately keeps distance-only matching while stopped
    /// or when Core Location cannot provide a useful course.
    let courseDifferenceDegrees: Double?

    init(distanceFromRoute: CLLocationDistance, remainingOnStep: CLLocationDistance,
         stepDistance: CLLocationDistance = 0,
         courseDifferenceDegrees: Double? = nil) {
        self.distanceFromRoute = distanceFromRoute
        self.remainingOnStep = remainingOnStep
        self.stepDistance = stepDistance
        self.courseDifferenceDegrees = courseDifferenceDegrees
    }
}

/// Distance alone cannot distinguish two carriageways, a flyover, or the
/// parallel motorway and exit ramp at a junction. A live, reliable vehicle
/// course gives us the missing direction without making guidance dependent on
/// a compass while the car is stationary.
enum NavigationCourseMatchingPolicy {
    static let maximumPlausibleDifference = 80.0

    static func angularDifference(courseDegrees: Double,
                                  routeCourseDegrees: Double) -> Double? {
        guard courseDegrees.isFinite, routeCourseDegrees.isFinite,
              courseDegrees >= 0, courseDegrees < 360,
              routeCourseDegrees >= 0, routeCourseDegrees < 360 else { return nil }
        let raw = abs(courseDegrees - routeCourseDegrees).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    static func isPlausible(_ difference: Double?) -> Bool {
        guard let difference else { return true }
        return difference.isFinite && difference <= maximumPlausibleDifference
    }

    static func routeCourse(near coordinate: CLLocationCoordinate2D,
                            coordinates: [CLLocationCoordinate2D]) -> Double? {
        guard coordinates.count > 1 else { return nil }
        let target = MKMapPoint(coordinate)
        let points = coordinates.map(MKMapPoint.init)
        var bestIndex: Int?
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for index in points.indices.dropLast() {
            let projection = segmentProjection(target, points[index], points[index + 1])
            guard projection.distance < bestDistance else { continue }
            bestDistance = projection.distance
            bestIndex = index
        }
        guard let bestIndex else { return nil }
        return bearing(from: coordinates[bestIndex], to: coordinates[bestIndex + 1])
    }

    static func bearing(from start: CLLocationCoordinate2D,
                        to end: CLLocationCoordinate2D) -> Double? {
        guard start.latitude.isFinite, start.longitude.isFinite,
              end.latitude.isFinite, end.longitude.isFinite else { return nil }
        let latitude1 = start.latitude * .pi / 180
        let latitude2 = end.latitude * .pi / 180
        let longitudeDelta = (end.longitude - start.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) -
            sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        guard abs(x) > .ulpOfOne || abs(y) > .ulpOfOne else { return nil }
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func segmentProjection(_ point: MKMapPoint, _ start: MKMapPoint,
                                          _ end: MKMapPoint)
        -> (point: MKMapPoint, distance: CLLocationDistance) {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projected = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
        return (projected, point.distance(to: projected))
    }
}

/// Advances through route steps in order. A geometrically close future step
/// (parallel carriageway, bridge or cloverleaf ramp) is not enough to skip
/// ahead; normal advancement is allowed only at the current step's end.
enum NavigationStepSelectionPolicy {
    /// Prevents a crossing or parallel piece of the same long route from
    /// snapping guidance hours ahead after one inaccurate tunnel fix.
    private static let maximumRecoveryStepAdvance = 16
    private static let maximumMeasuredRecoveryStepAdvance = 80
    private static let maximumRecoveryDistance: CLLocationDistance = 25_000

    static func selectedIndex(current: Int, metrics: [NavigationStepMetric],
                              transitionRadius: CLLocationDistance,
                              allowsFullRecovery: Bool = false) -> Int {
        guard metrics.indices.contains(current) else { return 0 }
        // Do not let a coarse GPS accuracy enlarge the junction far enough to
        // advance before the driver has actually reached the turn. Advancing
        // at 20–25 metres can discard the current maneuver and its final
        // spoken cue. Eight to fifteen metres is still tolerant of ordinary
        // road-level GPS drift; the explicit recovery path below handles real
        // gaps after tunnels or background suspension.
        let radius = min(15, max(8, transitionRadius))

        // Only the first fix of a restored offline route may search the whole
        // remaining journey. Prefer the earliest plausible road segment over
        // a microscopically closer later crossing, so loops and cloverleafs do
        // not skip required sections. Normal live updates keep the tight
        // forward window below.
        if allowsFullRecovery, metrics[current].distanceFromRoute > 250 {
            if let earliestPlausible = metrics.indices.dropFirst(current).first(where: {
                metrics[$0].distanceFromRoute <= max(45, radius * 1.5) &&
                    NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }) {
                return earliestPlausible
            }
            if let nearest = metrics.indices.dropFirst(current).filter({
                NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }).min(by: {
                metrics[$0].distanceFromRoute < metrics[$1].distanceFromRoute
            }), metrics[nearest].distanceFromRoute + 250 < metrics[current].distanceFromRoute {
                return nearest
            }
        }

        // A large discontinuity is the explicit recovery path after a tunnel,
        // long pause or sparse background update. Recovery only moves forward.
        let recovery = recoveryIndices(current: current, metrics: metrics)
        if metrics[current].distanceFromRoute > 250 {
            if let earliestPlausible = recovery.first(where: {
                metrics[$0].distanceFromRoute <= max(45, radius * 1.5) &&
                    NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }) {
                return earliestPlausible
            }
            if let recovered = recovery.filter({
                NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }).min(by: {
                metrics[$0].distanceFromRoute < metrics[$1].distanceFromRoute
            }), metrics[recovered].distanceFromRoute + 80 < metrics[current].distanceFromRoute {
                return recovered
            }
        }

        var selected = current
        while metrics.indices.contains(selected + 1) {
            let active = metrics[selected]
            let next = metrics[selected + 1]
            let headingMatches = NavigationCourseMatchingPolicy.isPlausible(
                next.courseDifferenceDegrees
            )
            let reachedJunction = active.remainingOnStep <= radius &&
                next.distanceFromRoute <= radius * 1.5 && headingMatches
            let clearlyPastStep = active.distanceFromRoute > 60 &&
                next.distanceFromRoute + 30 < active.distanceFromRoute &&
                next.distanceFromRoute <= 45 && headingMatches
            guard reachedJunction || clearlyPastStep else { break }
            selected += 1
        }
        return selected
    }

    private static func recoveryIndices(current: Int,
                                        metrics: [NavigationStepMetric]) -> Range<Int> {
        let hasMeasuredDistances = metrics[current...].contains { $0.stepDistance > 0 }
        guard hasMeasuredDistances else {
            return current..<min(metrics.count, current + maximumRecoveryStepAdvance + 1)
        }
        var end = current
        var distance: CLLocationDistance = 0
        while end + 1 < metrics.count,
              end - current < maximumMeasuredRecoveryStepAdvance {
            distance += max(0, metrics[end].stepDistance)
            if distance >= maximumRecoveryDistance, end - current >= 3 { break }
            end += 1
        }
        return current..<min(metrics.count, end + 1)
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

enum RouteRemainingTimePolicy {
    /// Preserves MapKit's per-leg traffic/road characteristics. A slow pass
    /// followed by a fast motorway must not inherit one whole-trip average.
    static func estimate(currentLegRemainingDistance: Double,
                         currentLegDistance: Double,
                         currentLegTravelTime: TimeInterval,
                         followingLegTravelTimes: [TimeInterval]) -> TimeInterval? {
        guard currentLegRemainingDistance.isFinite,
              currentLegDistance.isFinite, currentLegDistance > 0,
              currentLegTravelTime.isFinite, currentLegTravelTime >= 0 else { return nil }
        let fraction = min(1, max(0, currentLegRemainingDistance / currentLegDistance))
        let following = followingLegTravelTimes.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        return currentLegTravelTime * fraction + following
    }
}

enum OfflineRouteRemainingTimePolicy {
    /// Reconstructs the remaining time from cached MapKit leg estimates. The
    /// current leg is reduced proportionally while every later leg keeps its
    /// own road and traffic characteristics.
    static func estimate(totalRemainingDistance: Double,
                         currentLegIndex: Int,
                         legs: [(distance: Double, travelTime: TimeInterval)]) -> TimeInterval? {
        guard totalRemainingDistance.isFinite, totalRemainingDistance >= 0,
              legs.indices.contains(currentLegIndex) else { return nil }
        let following = legs.dropFirst(currentLegIndex + 1)
        let followingDistance = following.reduce(0) { $0 + max(0, $1.distance) }
        let currentRemaining = max(0, totalRemainingDistance - followingDistance)
        let current = legs[currentLegIndex]
        return RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: currentRemaining,
            currentLegDistance: current.distance,
            currentLegTravelTime: current.travelTime,
            followingLegTravelTimes: following.map(\.travelTime)
        )
    }
}

enum NavigationDeviationPolicy {
    static let requiredConsecutiveFixes = 3

    static func threshold(horizontalAccuracy: Double, speedMetresPerSecond: Double) -> Double {
        max(100, horizontalAccuracy * 3, min(220, max(speedMetresPerSecond, 0) * 4))
    }

    static func isOutsideCorridor(distanceFromRoute: Double,
                                  horizontalAccuracy: Double,
                                  speedMetresPerSecond: Double) -> Bool {
        guard distanceFromRoute.isFinite,
              horizontalAccuracy >= 0, horizontalAccuracy <= 65 else { return false }
        return distanceFromRoute > threshold(
            horizontalAccuracy: horizontalAccuracy,
            speedMetresPerSecond: speedMetresPerSecond
        )
    }

    static func shouldAccumulate(distanceFromRoute: Double, previousDistance: Double?,
                                 horizontalAccuracy: Double, speedMetresPerSecond: Double,
                                 rerouteAllowed: Bool = true) -> Bool {
        guard rerouteAllowed,
              speedMetresPerSecond >= 2.5,
              isOutsideCorridor(distanceFromRoute: distanceFromRoute,
                                horizontalAccuracy: horizontalAccuracy,
                                speedMetresPerSecond: speedMetresPerSecond) else { return false }
        if let previousDistance, distanceFromRoute + 30 < previousDistance { return false }
        return true
    }

    static func confirmationDuration(speedMetresPerSecond: Double) -> TimeInterval {
        speedMetresPerSecond > 22 ? 8 : 12
    }

    static func isConfirmed(elapsed: TimeInterval, consecutiveFixes: Int,
                            speedMetresPerSecond: Double) -> Bool {
        consecutiveFixes >= requiredConsecutiveFixes &&
            elapsed >= confirmationDuration(speedMetresPerSecond: speedMetresPerSecond)
    }
}

/// Deviation detection must compare the car with the route it is supposed to
/// drive now. Looking at the complete journey lets a later crossing, parallel
/// motorway or return loop mask a genuine wrong turn.
enum NavigationDeviationCorridorPolicy {
    /// Keeps a tiny amount of the route behind the cursor in scope. Map
    /// matching can briefly advance the cursor at motorway junctions or after
    /// receiving a batched location update; excluding the road the car is
    /// actually still on would otherwise trigger a false reroute.
    static let backwardStepCount = 2
    static let forwardStepCount = 16

    static func indices(current: Int, stepCount: Int) -> Range<Int> {
        guard stepCount > 0 else { return 0..<0 }
        let cursor = min(max(0, current), stepCount - 1)
        let start = max(0, cursor - backwardStepCount)
        let end = min(stepCount, cursor + forwardStepCount + 1)
        return start..<end
    }
}

/// Failed MapKit requests must not turn a genuine deviation into a spoken
/// recalculation loop. Successful reroutes retain the short normal cooldown;
/// repeated failures back off while the old route remains visible.
enum NavigationRerouteRetryPolicy {
    static func cooldown(consecutiveFailures: Int) -> TimeInterval {
        switch max(0, consecutiveFailures) {
        case 0: 45
        case 1: 2 * 60
        default: 5 * 60
        }
    }

    static func mayRetry(lastAttempt: Date?, consecutiveFailures: Int,
                         now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= cooldown(consecutiveFailures: consecutiveFailures)
    }
}

/// MapKit normally answers quickly, but an interrupted network request can
/// remain suspended for much longer. The navigation UI must never stay in a
/// permanent "recalculating" state because of one lost response.
enum NavigationRerouteWatchdogPolicy {
    static let timeout: TimeInterval = 45
    static let timeoutNanoseconds: UInt64 = UInt64(timeout * 1_000_000_000)

    static func hasTimedOut(startedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= timeout
    }
}

enum OfflineRouteRecoveryPolicy {
    static let retryInterval: TimeInterval = 90

    static func shouldAttempt(lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }

    static func acceptsOnlineResult(calculationSucceeded: Bool,
                                    navigationActive: Bool,
                                    stillUsingOfflineGuidance: Bool) -> Bool {
        calculationSucceeded && navigationActive && !stillUsingOfflineGuidance
    }
}

/// A persistent trip lock must survive a transient MapKit outage. Automatic
/// restoration is retried at a calm cadence instead of being permanently
/// consumed by the first failed request or hammering MapKit on every GPS fix.
enum RouteLockRestorePolicy {
    static let retryInterval: TimeInterval = 90

    static func shouldAttempt(navigationActive: Bool, attemptInProgress: Bool,
                              lastAttempt: Date?, now: Date = Date()) -> Bool {
        guard !navigationActive, !attemptInProgress else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }
}

enum RouteRestoreModePolicy {
    enum Mode: Equatable { case online, offline, staleLive, unavailable }

    static func mode(onlineCalculationSucceeded: Bool, hasLiveRoute: Bool,
                     hasMatchingOfflineRoute: Bool) -> Mode {
        if onlineCalculationSucceeded && hasLiveRoute { return .online }
        if hasMatchingOfflineRoute { return .offline }
        if hasLiveRoute { return .staleLive }
        return .unavailable
    }
}

enum NavigationDestinationIdentityPolicy {
    static func matches(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D,
                        toleranceMetres: CLLocationDistance = 25) -> Bool {
        guard let lhs else { return false }
        return CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(
            from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        ) <= toleranceMetres
    }
}

/// Destination activation is transactional: a failed request may restore its
/// own snapshot only while it is still the latest user selection.
enum DestinationActivationRollbackPolicy {
    static func shouldRollback(request: UUID, current: UUID) -> Bool {
        request == current
    }
}

/// Slow route enrichment (fuel, amenities, speed limits and tolls) may only
/// publish while both its route and its own request are still current.
enum RouteEnrichmentPublicationPolicy {
    static func isCurrent(route: UUID, currentRoute: UUID,
                          request: UUID, currentRequest: UUID) -> Bool {
        route == currentRoute && request == currentRequest
    }
}

/// A failed route mutation may restore its snapshot only when the persisted
/// state still equals the exact mutation that initiated the calculation.
/// Newer stop edits or live waypoint progress must always win.
enum RouteMutationRollbackPolicy {
    static func shouldRollback<State: Equatable>(current: State, mutated: State) -> Bool {
        current == mutated
    }
}

/// Async guidance work belongs to both one navigation session and one work
/// item. Stopping, arriving, or starting another drive invalidates both.
enum NavigationAsyncWorkPolicy {
    static func isCurrent(navigationActive: Bool,
                          session: UUID, currentSession: UUID,
                          work: UUID, currentWork: UUID) -> Bool {
        navigationActive && session == currentSession && work == currentWork
    }

    /// Route calculations started by guidance are allowed to publish only
    /// while their navigation session still exists. A reroute additionally
    /// belongs to one watchdog-controlled work item. Foreground route planning
    /// passes no session and remains independent of navigation lifecycle.
    static func mayCommitCalculation(navigationActive: Bool,
                                     session: UUID?, currentSession: UUID,
                                     work: UUID?, currentWork: UUID) -> Bool {
        guard let session else { return true }
        guard navigationActive, session == currentSession else { return false }
        return work.map { $0 == currentWork } ?? true
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

/// Cached turn-by-turn geometry is a short-lived safety net for tunnels,
/// roaming gaps and multi-day journeys, not a permanent substitute for fresh
/// routing data. A small future tolerance survives harmless clock correction.
enum OfflineRouteFreshnessPolicy {
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// A deliberately active route lock proves that the driver still intends
    /// to finish this trip. Keep its last known turn-by-turn geometry long
    /// enough for a multi-week holiday, while still forcing a fresh route
    /// after a month because closures and road layouts may have changed.
    static let activeTripMaximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let futureTolerance: TimeInterval = 5 * 60

    static func isUsable(savedAt: Date, belongsToActiveTrip: Bool = false,
                         now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        let permittedAge = belongsToActiveTrip ? activeTripMaximumAge : maximumAge
        return age >= -futureTolerance && age <= permittedAge
    }
}

enum OfflineRouteTripIdentityPolicy {
    static func belongs(cacheTripID: UUID?, activeTripID: UUID?, active: Bool) -> Bool {
        guard active, let cacheTripID, let activeTripID else { return false }
        return cacheTripID == activeTripID
    }
}

enum OfflineRouteAvailabilityPolicy {
    static func isUsable(savedAt: Date,
                         cacheName: String, cacheCoordinate: CLLocationCoordinate2D?,
                         destinationName: String?, destinationCoordinate: CLLocationCoordinate2D?,
                         belongsToActiveTrip: Bool = false,
                         now: Date = Date()) -> Bool {
        guard let destinationName else { return false }
        return OfflineRouteFreshnessPolicy.isUsable(
            savedAt: savedAt, belongsToActiveTrip: belongsToActiveTrip, now: now
        ) &&
            OfflineRouteCachePolicy.matches(
                cacheName: cacheName, cacheCoordinate: cacheCoordinate,
                destinationName: destinationName, destinationCoordinate: destinationCoordinate
            )
    }
}

enum RouteSearchPolicy {
    struct DetourAnchors {
        let entry: CLLocationCoordinate2D
        let exit: CLLocationCoordinate2D
        let baselineMetres: CLLocationDistance
    }

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

    /// Removes the materially completed part before issuing MapKit searches.
    /// Filtering only after the provider request wastes calls on towns behind
    /// the vehicle and can crowd useful future results out of the response.
    static func remainingRouteCoordinates(_ coordinates: [CLLocationCoordinate2D],
                                          currentProgress: Double)
        -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        let progress = RouteGeometryProgress.cumulativeFractions(coordinates)
        let lowerBound = max(0, min(1, currentProgress) - 0.02)
        let first = progress.firstIndex(where: { $0 >= lowerBound }) ?? (coordinates.count - 1)
        return Array(coordinates[first...])
    }

    /// Uses compact regions for local trips while retaining enough overlap to
    /// cover a long motorway journey with a small, bounded number of calls.
    static func searchRadiusMetres(routeCoordinates: [CLLocationCoordinate2D],
                                   searchPointCount: Int) -> CLLocationDistance {
        guard routeCoordinates.count > 1, searchPointCount > 0 else { return 15_000 }
        let distance = zip(routeCoordinates, routeCoordinates.dropFirst()).reduce(0.0) {
            $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }
        let intervals = max(1, searchPointCount - 1)
        let overlappingHalfSpacing = distance / Double(intervals) * 0.6
        return min(150_000, max(15_000, overlappingHalfSpacing))
    }

    /// A stop that needs more than 20 km of additional driving is not an
    /// "along the route" result, even if it looks close across a river,
    /// motorway barrier or mountain in straight-line geometry.
    static func acceptsDetour(_ metres: CLLocationDistance) -> Bool {
        metres.isFinite && metres >= 0 && metres <= 20_000
    }

    /// Without a successful driving route, straight-line proximity is only a
    /// useful fallback very close to the corridor. Across a river, motorway
    /// barrier or mountain, doubling several kilometres of air distance can
    /// severely understate the real detour and must not be presented as fact.
    static func estimatedDetour(airDistance: CLLocationDistance) -> CLLocationDistance? {
        guard airDistance.isFinite, airDistance >= 0, airDistance <= 3_000 else { return nil }
        let estimate = airDistance * 2
        return acceptsDetour(estimate) ? estimate : nil
    }

    /// Measures a stop in the actual driving direction. Routing from one
    /// corridor point to the POI and back to that same point can invent a
    /// motorway U-turn. Entry and exit anchors straddle the stop instead;
    /// their normal route distance is subtracted from the via-POI distance.
    static func detourAnchors(routeCoordinates: [CLLocationCoordinate2D],
                              progress: Double,
                              halfSpanMetres: CLLocationDistance = 1_000)
        -> DetourAnchors? {
        guard routeCoordinates.count > 1 else { return nil }
        let fractions = RouteGeometryProgress.cumulativeFractions(routeCoordinates)
        let total = zip(routeCoordinates, routeCoordinates.dropFirst()).reduce(0.0) {
            $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }
        guard total.isFinite, total > 0 else { return nil }
        let centre = min(1, max(0, progress))
        let delta = max(0, halfSpanMetres) / total
        let entryProgress = max(0, centre - delta)
        let exitProgress = min(1, centre + delta)
        guard exitProgress > entryProgress,
              let entry = coordinate(at: entryProgress, coordinates: routeCoordinates,
                                     fractions: fractions),
              let exit = coordinate(at: exitProgress, coordinates: routeCoordinates,
                                    fractions: fractions) else { return nil }
        return .init(entry: entry, exit: exit,
                     baselineMetres: (exitProgress - entryProgress) * total)
    }

    static func additionalDistance(viaDistance: CLLocationDistance,
                                   baselineDistance: CLLocationDistance)
        -> CLLocationDistance? {
        guard viaDistance.isFinite, viaDistance >= 0,
              baselineDistance.isFinite, baselineDistance >= 0 else { return nil }
        return max(0, viaDistance - baselineDistance)
    }

    /// Provider results commonly contain many branches of the same chain in
    /// one town. Spending every directions request there makes a long-route
    /// search look empty farther ahead. Cluster nearby route progress and
    /// retain the geometrically closest candidate from each section before
    /// applying the strict request limit.
    static func diverseShortlist<C>(_ candidates: [C], maximum: Int,
                                    minimumProgressSeparation: Double = 0.015,
                                    progress: (C) -> Double,
                                    airDistance: (C) -> CLLocationDistance) -> [C] {
        guard maximum > 0 else { return [] }
        let separation = max(0, minimumProgressSeparation)
        let sorted = candidates.sorted {
            let lhsProgress = progress($0)
            let rhsProgress = progress($1)
            return lhsProgress == rhsProgress
                ? airDistance($0) < airDistance($1)
                : lhsProgress < rhsProgress
        }
        var clusters: [[C]] = []
        for candidate in sorted {
            if let first = clusters.last?.first,
               progress(candidate) - progress(first) < separation {
                clusters[clusters.count - 1].append(candidate)
            } else {
                clusters.append([candidate])
            }
        }
        return clusters.compactMap { cluster in
            cluster.min { airDistance($0) < airDistance($1) }
        }
        .prefix(maximum)
        .map { $0 }
    }

    private static func coordinate(at progress: Double,
                                   coordinates: [CLLocationCoordinate2D],
                                   fractions: [Double]) -> CLLocationCoordinate2D? {
        guard coordinates.count == fractions.count, !coordinates.isEmpty else { return nil }
        let target = min(1, max(0, progress))
        guard let upper = fractions.firstIndex(where: { $0 >= target }) else {
            return coordinates.last
        }
        guard upper > 0 else { return coordinates[0] }
        let lower = upper - 1
        let span = fractions[upper] - fractions[lower]
        let interpolation = span > 0 ? (target - fractions[lower]) / span : 0
        return .init(
            latitude: coordinates[lower].latitude +
                (coordinates[upper].latitude - coordinates[lower].latitude) * interpolation,
            longitude: coordinates[lower].longitude +
                (coordinates[upper].longitude - coordinates[lower].longitude) * interpolation
        )
    }
}

enum RouteSearchCompletionDisposition: Equatable {
    case publish
    case discardAndFinish
    case superseded
}

enum RouteSearchCompletionPolicy {
    /// A newer search owns all visible state and must never be modified by an
    /// older completion. If only the route or edited query changed, this
    /// request still owns the spinner and has to finish it without publishing
    /// results calculated for stale geometry or text.
    static func disposition(request: UUID, currentRequest: UUID,
                            routeGeneration: UUID, currentRouteGeneration: UUID,
                            query: String, currentQuery: String)
        -> RouteSearchCompletionDisposition {
        guard request == currentRequest else { return .superseded }
        guard routeGeneration == currentRouteGeneration,
              query == currentQuery else { return .discardAndFinish }
        return .publish
    }
}

struct OfflineGuidanceStep {
    let instruction: String
    let distance: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]
}

enum OfflineGuidanceResumePolicy {
    /// Converts the monotonic progress persisted by the trip lock into a safe
    /// cached-step cursor. A small backward allowance keeps the next junction
    /// visible when the last checkpoint was written just after crossing it,
    /// while still preventing a restart at an old, geometrically nearby loop.
    static func stepIndex(steps: [OfflineGuidanceStep], persistedProgress: Double?,
                          backwardAllowance: Double = 0.015) -> Int {
        guard !steps.isEmpty, let persistedProgress, persistedProgress.isFinite else { return 0 }
        let distances = steps.map { max(0, $0.distance) }
        let total = distances.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = max(0, min(1, persistedProgress) - max(0, backwardAllowance)) * total
        var accumulated = 0.0
        for index in steps.indices {
            let end = accumulated + distances[index]
            if target <= end || index == steps.index(before: steps.endIndex) { return index }
            accumulated = end
        }
        return 0
    }
}

struct OfflineGuidanceProgress: Equatable {
    let currentStepIndex: Int
    let maneuverStepIndex: Int
    let instruction: String
    let distanceToManeuver: CLLocationDistance
    let remainingDistance: CLLocationDistance
    let upcomingInstructions: [String]
    let followingManeuverDistance: CLLocationDistance?
    let distanceFromRoute: CLLocationDistance
}

enum OfflineGuidanceEngine {
    static func progress(at coordinate: CLLocationCoordinate2D, currentIndex: Int,
                         steps: [OfflineGuidanceStep],
                         transitionRadius: CLLocationDistance,
                         allowsFullRecovery: Bool = false,
                         courseDegrees: Double? = nil) -> OfflineGuidanceProgress? {
        guard !steps.isEmpty else { return nil }
        let metrics = steps.map {
            geometryMetric(
                from: coordinate, on: $0.coordinates,
                stepDistance: $0.distance, courseDegrees: courseDegrees
            )
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
                         followingManeuverDistance: nil,
                         distanceFromRoute: metrics[selected].distanceFromRoute)
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
                     followingManeuverDistance: followingDistance,
                     distanceFromRoute: metrics[selected].distanceFromRoute)
    }

    private static func geometryMetric(from coordinate: CLLocationCoordinate2D,
                                       on coordinates: [CLLocationCoordinate2D],
                                       stepDistance: CLLocationDistance,
                                       courseDegrees: Double?) -> NavigationStepMetric {
        guard coordinates.count > 1 else {
            return .init(distanceFromRoute: .greatestFiniteMagnitude,
                         remainingOnStep: .greatestFiniteMagnitude,
                         stepDistance: stepDistance)
        }
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
        let difference = courseDegrees.flatMap { course in
            NavigationCourseMatchingPolicy.bearing(
                from: coordinates[best.index], to: coordinates[best.index + 1]
            ).flatMap {
                NavigationCourseMatchingPolicy.angularDifference(
                    courseDegrees: course, routeCourseDegrees: $0
                )
            }
        }
        return .init(distanceFromRoute: best.distance, remainingOnStep: value,
                     stepDistance: stepDistance, courseDifferenceDegrees: difference)
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
