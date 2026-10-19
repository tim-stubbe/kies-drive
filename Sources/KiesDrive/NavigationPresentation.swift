import Foundation
import CoreLocation
import MapKit

enum NavigationIdleTimerPolicy {
    /// Navigation may keep the display awake only while guidance is running
    /// and the app is actually in the foreground. Browsing the map must keep
    /// the user's normal Auto-Lock setting intact.
    static func shouldDisable(navigationActive: Bool, sceneActive: Bool) -> Bool {
        navigationActive && sceneActive
    }
}

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

enum NavigationSearchBatchPolicy {
    static let timeoutNanoseconds: UInt64 = 8_000_000_000
    static let maximumConcurrentRouteSearches = 5
    static let maximumConcurrentAmenitySearches = 8
    static let maximumConcurrentDetourCalculations = 3
    static let usefulResultCount = 8
    static let minimumCompletedSearches = 2

    static func uniqueResultCount<Result>(
        _ results: [Result], areDuplicates: (Result, Result) -> Bool
    ) -> Int {
        var unique: [Result] = []
        for result in results where !unique.contains(where: { areDuplicates(result, $0) }) {
            unique.append(result)
        }
        return unique.count
    }

    static func shouldFinishEarly(uniqueResultCount: Int, completedSearches: Int,
                                  totalSearches: Int) -> Bool {
        totalSearches > completedSearches &&
            completedSearches >= minimumCompletedSearches &&
            uniqueResultCount >= usefulResultCount
    }

    static func detourBatches(candidateCount: Int) -> [Range<Int>] {
        guard candidateCount > 0 else { return [] }
        return stride(
            from: 0, to: candidateCount, by: maximumConcurrentDetourCalculations
        ).map { start in
            start..<min(candidateCount, start + maximumConcurrentDetourCalculations)
        }
    }
}

enum DestinationSearchCompletionPolicy {
    static func mayPublish(request: UUID, currentRequest: UUID,
                           query: String, currentText: String) -> Bool {
        request == currentRequest &&
            query == currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DestinationQuerySelectionPolicy {
    /// A text field is only a faithful representation of the selected map
    /// item while it still contains that item's label. As soon as the driver
    /// edits the query, the old coordinate must stop being actionable.
    static func stillRepresentsSelection(query: String,
                                         selectedName: String?,
                                         selectedTitle: String?) -> Bool {
        let query = normalised(query)
        guard !query.isEmpty else { return false }
        return [selectedName, selectedTitle].compactMap { $0 }.contains {
            normalised($0) == query
        }
    }

    private static func normalised(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

enum DestinationSearchBatchCompletionPolicy {
    enum Resolution: Equatable {
        case results
        case noResults
        case failed
    }

    /// An empty, successful MapKit response is not a transport failure. Keep
    /// that distinction so the UI can tell the driver to refine the query
    /// instead of appearing unresponsive or blaming the connection.
    static func resolution(resultCount: Int, failureCount: Int,
                           searchCount: Int) -> Resolution {
        if resultCount > 0 { return .results }
        if searchCount > 0, failureCount >= searchCount { return .failed }
        return .noResults
    }
}

enum RouteSearchEmptyResultPolicy {
    static func message(mapMatches: Int, corridorMatches: Int,
                        acceptableDetours: Int) -> String? {
        guard acceptableDetours == 0 else { return nil }
        if mapMatches == 0 {
            return "Keine passenden Orte entlang der verbleibenden Route gefunden."
        }
        if corridorMatches == 0 {
            return "Treffer gefunden, aber keiner liegt sinnvoll voraus an deiner Route."
        }
        return "Treffer gefunden, aber der zusätzliche Fahrweg wäre zu groß."
    }
}

enum DestinationActivationBaselinePolicy {
    /// Rapid destination taps form one replacement transaction. Every newer
    /// request must keep the original stable baseline instead of treating the
    /// previous in-flight destination as a valid rollback target.
    static func choose<Value>(existing: Value?, current: @autoclosure () -> Value) -> Value {
        existing ?? current()
    }
}

enum RouteMutationBaselinePolicy {
    static func choose<Value>(existing: Value?, current: @autoclosure () -> Value) -> Value {
        existing ?? current()
    }
}

enum DestinationSearchRankingPolicy {
    static func relevanceScore(query: String, name: String?, title: String?) -> Double {
        let query = normalised(query)
        guard !query.isEmpty else { return 10 }
        let values = [name, title].compactMap { value -> String? in
            let value = normalised(value ?? "")
            return value.isEmpty ? nil : value
        }
        if values.contains(query) { return 0 }
        // Preserve locality/street qualifiers from the user's full query.
        // A short generic result name such as "Hochheim" must not outrank an
        // address that actually contains "Hochheim am Main" merely because
        // the query itself begins with that short name.
        if values.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if values.contains(where: { $0.contains(query) }) { return 1.5 }
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let overlap = values.map { value -> Double in
            let tokens = Set(value.split(separator: " ").map(String.init))
            guard !queryTokens.isEmpty else { return 0 }
            return Double(queryTokens.intersection(tokens).count) / Double(queryTokens.count)
        }.max() ?? 0
        return overlap > 0 ? 4 - overlap : 10
    }

    static func isDuplicate(name: String?, coordinate: CLLocationCoordinate2D,
                            existingName: String?, existingCoordinate: CLLocationCoordinate2D,
                            toleranceMetres: CLLocationDistance = 40) -> Bool {
        guard normalised(name ?? "") == normalised(existingName ?? "") else { return false }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(
            from: CLLocation(latitude: existingCoordinate.latitude,
                             longitude: existingCoordinate.longitude)
        ) <= toleranceMetres
    }

    private static func normalised(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Brand names vary between straight/curly apostrophes or omit
            // them entirely (for example McDonald's/McDonalds). Treat those
            // spellings as the same POI instead of creating duplicate rows.
            .replacingOccurrences(of: #"['’]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RouteComparisonPublicationPolicy {
    static func mayPublish(requestRoute: UUID, currentRoute: UUID,
                           stillEligible: Bool) -> Bool {
        requestRoute == currentRoute && stillEligible
    }
}

enum RouteGeometryEndpointPolicy {
    /// `MKPolyline.coordinate` is a representative overlay coordinate and is
    /// not guaranteed to be its first vertex. Toll and route-origin lookups
    /// must use the actual beginning of the selected geometry.
    static func origin(
        coordinates: [CLLocationCoordinate2D],
        fallback: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        coordinates.first ?? fallback
    }
}

enum CarPlayAlertPresentationPolicy {
    static func titleVariants(for message: String) -> [String] {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? ["Aktion nicht möglich"] : [cleaned, "Aktion nicht möglich"]
    }
}

enum CarPlayMapAppearancePolicy {
    static func mapType(for appearance: DriveMapAppearance) -> MKMapType {
        switch appearance {
        case .standard: .standard
        case .hybrid: .hybrid
        }
    }
}

enum CarPlayListPriorityPolicy {
    static func allocation(groupCounts: [Int], maximum: Int = 12) -> [Int] {
        var remaining = max(0, maximum)
        return groupCounts.map { count in
            let accepted = min(max(0, count), remaining)
            remaining -= accepted
            return accepted
        }
    }
}

enum CarPlaySpeedLimitBadgePolicy {
    enum State: Equatable {
        case hidden
        case numeric(value: Int, warning: Bool)
        case unrestricted
    }

    static func state(limit: SpeedLimitResult?, speedWarning: Bool,
                      navigationActive: Bool) -> State {
        guard navigationActive, let limit else { return .hidden }
        switch SpeedLimitPresentationPolicy.presentation(for: limit) {
        case .numeric(let value):
            return .numeric(value: value, warning: speedWarning)
        case .unrestricted:
            return .unrestricted
        case .unavailable:
            return .hidden
        }
    }
}

enum CarPlayRouteOptionPresentationPolicy {
    static func detail(enabled: Bool) -> String {
        enabled ? "Aktiv · antippen zum Ausschalten" : "Aus · antippen zum Einschalten"
    }

    static func symbol(enabled: Bool) -> String {
        enabled ? "checkmark.circle.fill" : "circle"
    }
}

enum FuelStationPricePresentationPolicy {
    static func compact(price: Double, cached: Bool) -> String {
        let value = String(format: "%.3f €", price)
        return cached ? "Gespeichert · \(value)" : value
    }

    static func sourceLabel(fuel: FuelKind, cached: Bool) -> String {
        cached ? "Zuletzt gespeicherter Preis · \(fuel.label)"
            : "Aktueller Serverpreis · \(fuel.label)"
    }
}

enum RouteFuelStationArrivalPolicy {
    /// Converts a station's installed-route position into an ETA on the
    /// remaining route. Opening data describes "now", so it may reject a
    /// nearby closed station without pretending that a distant one will still
    /// be closed hours later.
    static func secondsUntilArrival(candidateProgress: Double,
                                    currentProgress: Double,
                                    remainingTravelTime: TimeInterval)
        -> TimeInterval? {
        guard candidateProgress.isFinite, currentProgress.isFinite,
              remainingTravelTime.isFinite, remainingTravelTime >= 0 else { return nil }
        let current = min(1, max(0, currentProgress))
        let candidate = min(1, max(0, candidateProgress))
        guard candidate >= current else { return nil }
        guard current < 1 else { return 0 }
        let fraction = min(1, max(0, (candidate - current) / (1 - current)))
        return remainingTravelTime * fraction
    }
}

enum CarPlayBreakReminderPresentationPolicy {
    static func titleVariants(for message: String) -> [String] {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        return [cleaned, "Pause einplanen"]
    }
}

enum CarPlayStopReminderPresentationPolicy {
    enum Kind: Equatable { case rest, fuel, combined }

    static func kind(for message: String) -> Kind {
        let folded = message.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        let hasRest = folded.contains("pause") || folded.contains("rast")
        let hasFuel = folded.contains("tank")
        if hasRest && hasFuel { return .combined }
        return hasFuel ? .fuel : .rest
    }

    static func titleVariants(for message: String) -> [String] {
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let fallback: String
        switch kind(for: cleaned) {
        case .rest: fallback = "Pause einplanen"
        case .fuel: fallback = "Tankstopp einplanen"
        case .combined: fallback = "Fahrtstopp einplanen"
        }
        return [cleaned, fallback]
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
    let insertionRouteProgress: Double
    let afterDriving: TimeInterval?
    let afterDistanceMetres: Double?
}

enum PlannedRouteStopVisibilityPolicy {
    /// A stop at or behind the matched vehicle position must disappear from
    /// both phone and CarPlay. Keeping it actionable can create a U-turn on a
    /// motorway after a stale planning refresh.
    static func isAhead(_ candidate: Double, current: Double,
                        minimumLead: Double = 0.000_1) -> Bool {
        guard candidate.isFinite, current.isFinite else { return false }
        return candidate >= min(1, max(0, current) + max(0, minimumLead))
    }
}

enum RouteSearchSelectionPolicy {
    /// Search results are projections onto one exact route geometry. Once a
    /// reroute or alternative selection starts, their progress values are no
    /// longer safe insertion positions even if the POI itself still exists.
    static func accepts(resultRouteGeneration: UUID?, currentRouteGeneration: UUID) -> Bool {
        resultRouteGeneration.map { $0 == currentRouteGeneration } ?? true
    }

    static func isActionable(resultRouteGeneration: UUID?, currentRouteGeneration: UUID,
                             candidateProgress: Double, currentProgress: Double,
                             totalRouteDistance: CLLocationDistance,
                             navigationActive: Bool) -> Bool {
        guard accepts(resultRouteGeneration: resultRouteGeneration,
                      currentRouteGeneration: currentRouteGeneration) else { return false }
        guard navigationActive else { return true }
        return RouteSearchPolicy.isAhead(
            candidateProgress: candidateProgress,
            currentProgress: currentProgress,
            totalRouteDistance: totalRouteDistance
        )
    }
}

enum PlannedStopSelectionPolicy {
    /// A sheet or CarPlay list can remain visible while a reroute replaces its
    /// backing station list. Accept additions only when the same physical
    /// station still belongs to the current route; selected stops remain
    /// removable even after provider refreshes.
    static func acceptsFuelStation(
        id: String,
        coordinate: CLLocationCoordinate2D,
        currentlySelected: Bool,
        available: [FuelStation],
        candidateProgress: Double? = nil,
        currentProgress: Double = 0,
        totalRouteDistance: CLLocationDistance = 0,
        navigationActive: Bool = false
    ) -> Bool {
        if currentlySelected { return true }
        let selectedLocation = CLLocation(latitude: coordinate.latitude,
                                          longitude: coordinate.longitude)
        guard available.contains(where: { station in
            guard station.id == id else { return false }
            return selectedLocation.distance(from: CLLocation(
                latitude: station.lat, longitude: station.lon
            )) <= 30
        }) else { return false }
        guard navigationActive else { return true }
        guard let candidateProgress else { return false }
        return RouteSearchPolicy.isAhead(
            candidateProgress: candidateProgress,
            currentProgress: currentProgress,
            totalRouteDistance: totalRouteDistance
        )
    }

    /// Planned breaks are value snapshots. Requiring the value to still exist
    /// in the current plan rejects a stale card whose route position, opening
    /// state or chosen amenity changed during recalculation.
    static func acceptsBreak(_ plannedBreak: PlannedBreak,
                             currentPlan: LongTripPlan?) -> Bool {
        currentPlan?.results.contains { $0.breaks.contains(plannedBreak) } ?? false
    }

    static func acceptsCarPlayAction(_ action: CarPlayPlannedStopAction,
                                     currentPlan: LongTripPlan?) -> Bool {
        guard let result = currentPlan?.results.first else { return false }
        let matchingBreak = result.breaks.first {
            $0.candidate?.id == action.candidate.id &&
                abs($0.insertionRouteProgress - action.insertionRouteProgress) <= 0.000_1
        }
        let matchingFuel = result.fuelStops.first {
            $0.candidate?.id == action.candidate.id &&
                abs($0.insertionRouteProgress - action.insertionRouteProgress) <= 0.000_1
        }
        switch action.purpose {
        case .breakOnly: return matchingBreak != nil && matchingFuel == nil
        case .fuelOnly: return matchingBreak == nil && matchingFuel != nil
        case .breakAndFuel: return matchingBreak != nil && matchingFuel != nil
        }
    }
}

enum RouteStopMutationAdmission: Equatable {
    case started
    case coalesced
    case busy
}

struct RouteStopMutationGate {
    private var activeID: String?

    var isBusy: Bool { activeID != nil }

    /// Route-stop edits all replace the same route and persistent lock. They
    /// must therefore be serialized globally, not only per stop identifier.
    /// A repeated tap on the active item is harmless and is coalesced, while a
    /// different edit is rejected until the authoritative calculation ends.
    mutating func begin(_ id: String) -> RouteStopMutationAdmission {
        guard let activeID else {
            self.activeID = id
            return .started
        }
        return activeID == id ? .coalesced : .busy
    }

    mutating func finish(_ id: String) {
        guard activeID == id else { return }
        activeID = nil
    }

    func isActive(_ id: String) -> Bool {
        activeID == id
    }

    static func itemIdentifier(name: String, latitude: Double, longitude: Double) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let latitudeMicrodegrees = Int((latitude * 1_000_000).rounded())
        let longitudeMicrodegrees = Int((longitude * 1_000_000).rounded())
        return "poi:\(normalizedName):\(latitudeMicrodegrees):\(longitudeMicrodegrees)"
    }
}

enum CarPlayPlannedStopPolicy {
    /// CarPlay must remain short and glanceable. Prefer the earliest remaining
    /// stop from the currently selected scenario, combine fuel and rest at the
    /// same place, and never offer a stop that is already locked into the route.
    static func actions(plan: LongTripPlan?, existingWaypointIDs: Set<String>,
                        existingWaypointNames: Set<String>, currentRouteProgress: Double,
                        maximum: Int = 2)
        -> [CarPlayPlannedStopAction] {
        guard maximum > 0, currentRouteProgress.isFinite,
              let result = plan?.results.first else { return [] }
        let progress = min(1, max(0, currentRouteProgress))
        let normalizedNames = Set(existingWaypointNames.map(normalize))
        let remainingFuelStops = result.fuelStops.filter {
            PlannedRouteStopVisibilityPolicy.isAhead($0.insertionRouteProgress, current: progress)
        }
        let fuelByID = Dictionary(uniqueKeysWithValues: remainingFuelStops.compactMap { stop in
            stop.candidate.map { ($0.id, stop) }
        })
        var seen = Set<String>()
        var actions = result.breaks.compactMap { plannedBreak -> CarPlayPlannedStopAction? in
            guard PlannedRouteStopVisibilityPolicy.isAhead(
                    plannedBreak.insertionRouteProgress, current: progress
                  ),
                  let candidate = plannedBreak.candidate,
                  !isExisting(candidate, ids: existingWaypointIDs, names: normalizedNames),
                  seen.insert(candidate.id).inserted else { return nil }
            let fuelStop = fuelByID[candidate.id]
            return .init(candidate: candidate,
                         purpose: fuelStop == nil ? .breakOnly : .breakAndFuel,
                         insertionRouteProgress: plannedBreak.insertionRouteProgress,
                         afterDriving: plannedBreak.afterDriving,
                         afterDistanceMetres: fuelStop?.afterDistanceMetres)
        }
        actions += remainingFuelStops.compactMap { fuelStop -> CarPlayPlannedStopAction? in
            guard let candidate = fuelStop.candidate,
                  !isExisting(candidate, ids: existingWaypointIDs, names: normalizedNames),
                  seen.insert(candidate.id).inserted else { return nil }
            return .init(candidate: candidate, purpose: .fuelOnly,
                         insertionRouteProgress: fuelStop.insertionRouteProgress,
                         afterDriving: nil,
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

enum CarPlayPlannedStopDetailPolicy {
    static func text(for action: CarPlayPlannedStopAction) -> String {
        if let seconds = action.afterDriving, seconds.isFinite, seconds >= 0 {
            if seconds <= 60 { return "Pause jetzt einlegen" }
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 60
                ? "In etwa \(minutes / 60) Std. \(minutes % 60) Min."
                : "In etwa \(minutes) Min."
        }
        if let metres = action.afterDistanceMetres, metres.isFinite, metres >= 0 {
            if metres <= 1_000 {
                return action.purpose == .fuelOnly
                    ? "Bei nächster Gelegenheit tanken"
                    : "Stopp jetzt einplanen"
            }
            return String(format: "In etwa %.0f km", metres / 1_000)
        }
        return "Mit kleinem Umweg zur Route hinzufügen"
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

    var highwayExitLabel: String? {
        direction == .roundabout ? nil : exitLabel
    }

    var roundaboutExitNumber: Int? {
        guard direction == .roundabout, let exitLabel else { return nil }
        return Int(exitLabel.prefix { $0.isNumber })
    }

    init(_ instruction: String) {
        self.instruction = instruction.isEmpty ? "Route folgen" : instruction
        let lower = instruction.lowercased()
        if lower.contains("kreisverkehr") || lower.contains("roundabout") { direction = .roundabout }
        else if lower.contains("wenden") || lower.contains("u-turn") { direction = .uTurn }
        else { direction = Self.firstDirection(in: lower) }

        let pattern = #"(?i:Ausfahrt|Exit|Anschlussstelle)\s+([0-9]+(?:[A-Za-z]|-[A-Za-z0-9]+|\s+[A-Z])?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
           let range = Range(match.range(at: 1), in: instruction) {
            let number = instruction[range].replacingOccurrences(of: " ", with: "")
            exitLabel = "Ausfahrt \(number.uppercased())"
        } else {
            exitLabel = Self.roundaboutExitLabel(in: instruction)
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
        let exitSidePattern = #"(?:ausfahrt|exit|anschlussstelle)\s+(?:[0-9]+(?:\s*[-a-z])?\s+)?(links|rechts|left|right)\b"#
        if let regex = try? NSRegularExpression(pattern: exitSidePattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            switch text[range] {
            case "links", "left": return .left
            default: return .right
            }
        }
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
        if let separator = value.range(
            of: #"(?i)\s*[,;]\s*(?:dann|danach|anschließend)\b"#,
            options: .regularExpression
        ) {
            value = String(value[..<separator.lowerBound])
        }
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

    /// MapKit commonly describes roundabouts using an ordinal before the
    /// noun ("die zweite Ausfahrt" / "the 2nd exit"), unlike motorway exits
    /// where the number follows "Ausfahrt". Preserve that decisive lane cue
    /// in the large phone banner and CarPlay instruction variants.
    private static func roundaboutExitLabel(in instruction: String) -> String? {
        let words: [String: Int] = [
            "erste": 1, "ersten": 1, "first": 1,
            "zweite": 2, "zweiten": 2, "second": 2,
            "dritte": 3, "dritten": 3, "third": 3,
            "vierte": 4, "vierten": 4, "fourth": 4,
            "fünfte": 5, "fünften": 5, "fuenfte": 5, "fuenften": 5, "fifth": 5,
            "sechste": 6, "sechsten": 6, "sixth": 6,
            "siebte": 7, "siebten": 7, "seventh": 7,
            "achte": 8, "achten": 8, "eighth": 8,
            "neunte": 9, "neunten": 9, "ninth": 9,
            "zehnte": 10, "zehnten": 10, "tenth": 10,
            "elfte": 11, "elften": 11, "eleventh": 11,
            "zwölfte": 12, "zwölften": 12, "zwoelfte": 12, "zwoelften": 12, "twelfth": 12,
        ]
        let lower = instruction.lowercased()
        guard lower.contains("kreisverkehr") || lower.contains("roundabout") else { return nil }
        let numericPattern = #"\b([0-9]{1,2})(?:\.|st|nd|rd|th)?\s+(?:ausfahrt|exit)\b"#
        if let regex = try? NSRegularExpression(pattern: numericPattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower),
           let number = Int(lower[range]), (1...20).contains(number) {
            return "\(number). Ausfahrt"
        }
        let wordPattern = #"\b([\p{L}]+)\s+(?:ausfahrt|exit)\b"#
        if let regex = try? NSRegularExpression(pattern: wordPattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower),
           let number = words[String(lower[range])] {
            return "\(number). Ausfahrt"
        }
        return nil
    }
}

enum CarPlayManeuverSemantic: Equatable {
    case followRoad, straight, slightRight, right, sharpRight
    case slightLeft, left, sharpLeft, uTurn
    case highwayOffRampLeft, highwayOffRampRight
    case roundabout(exit: Int?)
}

enum CarPlayManeuverSemanticPolicy {
    static func semantic(for presentation: NavigationManeuverPresentation)
        -> CarPlayManeuverSemantic {
        if presentation.highwayExitLabel != nil {
            switch presentation.direction {
            case .left, .slightLeft, .sharpLeft: return .highwayOffRampLeft
            default: return .highwayOffRampRight
            }
        }
        switch presentation.direction {
        case .straight:
            return presentation.instruction.localizedCaseInsensitiveContains("folgen")
                ? .followRoad : .straight
        case .slightRight: return .slightRight
        case .right: return .right
        case .sharpRight: return .sharpRight
        case .slightLeft: return .slightLeft
        case .left: return .left
        case .sharpLeft: return .sharpLeft
        case .uTurn: return .uTurn
        case .roundabout: return .roundabout(exit: presentation.roundaboutExitNumber)
        }
    }
}

/// Converts MapKit's compact, sometimes symbol-heavy instructions into text
/// that a German navigation voice can pronounce naturally.
enum NavigationSpeechFormatter {
    static func spokenText(_ instruction: String, distance: CLLocationDistance? = nil) -> String {
        // Expand multi-character abbreviations before their punctuation is
        // normalised. Otherwise `km/h` becomes `km, h` before the dedicated
        // rule can make it understandable to the speech synthesizer.
        var text = replacing(#"(?i)\bkm\s*/\s*h\b"#, in: instruction,
                             with: "Kilometer pro Stunde")
        // Cached routes can outlive a device-language change and MapKit can
        // occasionally return an English maneuver near a border. A German
        // voice reading those verbs literally is difficult to understand, so
        // translate the small, well-defined navigation vocabulary first.
        let englishManeuvers: [(String, String)] = [
            (#"(?i)\bat the roundabout\b"#, "Im Kreisverkehr"),
            (#"(?i)\btake the\s+([0-9]{1,2})(?:st|nd|rd|th)\s+exit\b"#, "die $1. Ausfahrt nehmen"),
            (#"(?i)\buse the right(?:-hand)? lane to take exit\s+([0-9]{1,3}[A-Za-z]?)\b"#,
             "die rechte Spur benutzen und Ausfahrt $1 nehmen"),
            (#"(?i)\buse the left(?:-hand)? lane to take exit\s+([0-9]{1,3}[A-Za-z]?)\b"#,
             "die linke Spur benutzen und Ausfahrt $1 nehmen"),
            (#"(?i)\buse the (\d+) right lanes to take exit\s+([0-9]{1,3}[A-Za-z]?)\b"#,
             "die $1 rechten Spuren benutzen und Ausfahrt $2 nehmen"),
            (#"(?i)\buse the (\d+) left lanes to take exit\s+([0-9]{1,3}[A-Za-z]?)\b"#,
             "die $1 linken Spuren benutzen und Ausfahrt $2 nehmen"),
            (#"(?i)\btake exit\s+([0-9]{1,3}[A-Za-z]?)\b"#, "Ausfahrt $1 nehmen"),
            (#"(?i)\bexit\s+([0-9]{1,3}[A-Za-z]?)\b"#, "Ausfahrt $1 nehmen"),
            (#"(?i)\bexit the roundabout onto\b"#, "den Kreisverkehr verlassen auf"),
            (#"(?i)\btake the ramp(?: on the)? right onto\b"#, "die Auffahrt rechts nehmen auf"),
            (#"(?i)\btake the ramp(?: on the)? left onto\b"#, "die Auffahrt links nehmen auf"),
            (#"(?i)\btake the ramp(?: on the)? right\b"#, "die Auffahrt rechts nehmen"),
            (#"(?i)\btake the ramp(?: on the)? left\b"#, "die Auffahrt links nehmen"),
            (#"(?i)\btake the ramp onto\b"#, "die Auffahrt nehmen auf"),
            (#"(?i)\bmerge onto\b"#, "einfädeln auf"),
            (#"(?i)\bslight right onto\b"#, "leicht rechts abbiegen auf"),
            (#"(?i)\bslight left onto\b"#, "leicht links abbiegen auf"),
            (#"(?i)\bslight right\b"#, "leicht rechts abbiegen"),
            (#"(?i)\bslight left\b"#, "leicht links abbiegen"),
            (#"(?i)\bturn right onto\b"#, "rechts abbiegen auf"),
            (#"(?i)\bturn left onto\b"#, "links abbiegen auf"),
            (#"(?i)\bturn right\b"#, "rechts abbiegen"),
            (#"(?i)\bturn left\b"#, "links abbiegen"),
            (#"(?i)\bkeep right\b"#, "rechts halten"),
            (#"(?i)\bkeep left\b"#, "links halten"),
            (#"(?i)\bcontinue onto\b"#, "weiterfahren auf"),
            (#"(?i)\bcontinue on\b"#, "weiterfahren auf"),
            (#"(?i)\bcontinue straight\b"#, "geradeaus weiterfahren"),
            (#"(?i)\bkeep straight\b"#, "geradeaus weiterfahren"),
            (#"(?i)\bstay on\b"#, "weiterfahren auf"),
            (#"(?i)\bfollow signs for\b"#, "der Beschilderung folgen Richtung"),
            (#"(?i)\bmake a u[- ]turn\b"#, "bitte wenden"),
            (#"(?i)\byour destination is on the right\b"#, "Das Ziel befindet sich rechts"),
            (#"(?i)\byour destination is on the left\b"#, "Das Ziel befindet sich links"),
            (#"(?i)\byou have arrived at your destination\b"#, "Du hast dein Ziel erreicht"),
            (#"(?i)\b(?:toward|towards)\b"#, "Richtung"),
        ]
        for (pattern, replacement) in englishManeuvers {
            text = replacing(pattern, in: text, with: replacement)
        }
        text = text
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
            .replacingOccurrences(of: "[", with: ", ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "{", with: ", ")
            .replacingOccurrences(of: "}", with: " ")

        text = replacing(#"(?i)\bStr\."#, in: text, with: "Straße")
        text = replacing(#"(?i)\bRtg\.?(?=\s|$)"#, in: text, with: "Richtung")
        text = replacing(#"(?i)\bBhf\.?(?=\s|$)"#, in: text, with: "Bahnhof")
        text = replacing(#"\bAK(?=\s|$)"#, in: text, with: "Autobahnkreuz")
        text = replacing(#"\bAD(?=\s|$)"#, in: text, with: "Autobahndreieck")
        text = replacing(#"\bAS(?=\s|$)"#, in: text, with: "Anschlussstelle")
        // German state-road labels use `St` plus digits. Keep `St.` before a
        // place name distinct: there it conventionally means "Sankt".
        text = replacing(#"(?i)\bSt\.?\s*([0-9]{1,4})([a-z]?)\b"#,
                         in: text, with: "Staatsstraße $1$2")
        text = replacing(#"(?i)\bSt\.\s+(?=[A-ZÄÖÜ])"#, in: text, with: "Sankt ")
        text = replacing(#"(?i)\bBAB\s*([0-9]{1,3})\b"#, in: text, with: "Autobahn $1")
        // Exit suffixes and lettered road branches are written compactly on
        // signs, but several German system voices pronounce `69-A` or `A66a`
        // as one garbled word. Keep every sign component audible.
        text = replacing(
            #"(?i)\b(Ausfahrt|Exit|Anschlussstelle)\s+([0-9]{1,3})\s*[- ]\s*([A-Z])\b"#,
            in: text, with: "$1 $2 $3"
        )
        text = replacing(
            #"(?i)\b(Ausfahrt|Exit|Anschlussstelle)\s+([0-9]{1,3})([A-Z])\b"#,
            in: text, with: "$1 $2 $3"
        )
        text = replacingRoundaboutExitOrdinal(in: text)
        // Force a small spoken pause between road class and number. Compact
        // forms such as A66 or B40 otherwise sound like arbitrary words on
        // some installed German voices.
        // Include the common road classes encountered on European holiday
        // routes (for example Croatia D8, Slovenia H3/G1 and Italy SS13), not
        // only German A/B/E roads. Compact labels otherwise become a single
        // unintelligible word with some German voices.
        text = replacing(#"(?i)\b(SS|[ABDEGHKLMNRS])\s*([0-9]{1,4})([a-z]?)\b"#,
                         in: text, with: "$1 $2 $3")
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
                           followingDistance: CLLocationDistance?,
                           maximumFollowingDistance: CLLocationDistance = 450) -> String {
        let primary = spokenText(instruction, distance: distance)
        guard let followingInstruction, let followingDistance,
              followingDistance.isFinite, followingDistance >= 0,
              followingDistance <= max(0, maximumFollowingDistance) else { return primary }
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

    private static func replacingRoundaboutExitOrdinal(in value: String) -> String {
        let ordinals = [
            1: "erste", 2: "zweite", 3: "dritte", 4: "vierte",
            5: "fünfte", 6: "sechste", 7: "siebte", 8: "achte",
            9: "neunte", 10: "zehnte", 11: "elfte", 12: "zwölfte",
        ]
        guard value.localizedCaseInsensitiveContains("kreisverkehr"),
              let regex = try? NSRegularExpression(
                pattern: #"\b([1-9]|1[0-2])\.\s+(?=Ausfahrt\b)"#,
                options: [.caseInsensitive]
              ) else { return value }
        var result = value
        let matches = regex.matches(
            in: value, range: NSRange(value.startIndex..., in: value)
        ).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result),
                  let number = Int(result[numberRange]),
                  let ordinal = ordinals[number] else { continue }
            result.replaceSubrange(whole, with: ordinal + " ")
        }
        return result
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

enum NavigationVoiceSelectionPolicy {
    /// Voice quality is the audible requirement. Siri branding is only a
    /// tie-breaker among equally capable installed German voices; otherwise a
    /// compact Siri asset could incorrectly beat an enhanced or premium one.
    static func score(qualityRawValue: Int, identifier: String) -> Int {
        qualityRawValue * 100 +
            (identifier.localizedCaseInsensitiveContains("siri") ? 10 : 0)
    }

    /// A saved voice is only used while it remains installed. This lets an
    /// iCloud/device migration safely fall back to automatic voice selection.
    static func selectedIdentifier(preferred: String, available: [String]) -> String? {
        guard !preferred.isEmpty, available.contains(preferred) else { return nil }
        return preferred
    }
}

enum CarPlaySearchPurpose: Equatable {
    case destination
    case routeStop

    /// Selecting an along-route result must preserve the active destination
    /// and insert a removable comfort stop instead.
    var replacesDestination: Bool { self == .destination }
}

enum CarPlaySearchSelectionPolicy {
    static func accepts(
        resultGeneration: UUID, currentGeneration: UUID,
        resultPurpose: CarPlaySearchPurpose, currentPurpose: CarPlaySearchPurpose
    ) -> Bool {
        resultGeneration == currentGeneration && resultPurpose == currentPurpose
    }
}

enum NavigationAnnouncementStage: Int, Hashable, CaseIterable {
    case early
    case prepare
    case final
    case now

    static func stage(distance: CLLocationDistance, speedKmh: Double,
                      horizontalAccuracy: CLLocationAccuracy = 0) -> Self? {
        guard distance.isFinite, distance >= 0 else { return nil }
        let speedMetresPerSecond = max(0, speedKmh) / 3.6
        // Route projection and GPS error can point in opposite directions. A
        // driver shown as 480 m from an exit with ±60 m accuracy may already
        // be only 420 m away. Use that conservative edge for stage selection,
        // but cap the allowance so one coarse fix cannot trigger guidance
        // kilometres early. The spoken distance remains the displayed route
        // distance and is therefore never fabricated.
        let accuracyAllowance = horizontalAccuracy.isFinite
            ? min(65, max(0, horizontalAccuracy)) : 0
        let safetyDistance = max(0, distance - accuracyAllowance)
        // Account for audio-session activation, Bluetooth latency and the
        // spoken sentence itself. The old three/six-second horizons could
        // begin a motorway instruction only after the driver had to commit to
        // the exit. Keep "Jetzt" visually close to the junction through a
        // hard cap, while the preceding distance cue provides real reaction
        // time at speed.
        let nowDistance = min(180, max(30, speedMetresPerSecond * 3.5))
        if safetyDistance <= nowDistance { return .now }
        let finalDistance = min(450, max(70, speedMetresPerSecond * 7.5))
        if safetyDistance <= finalDistance { return .final }
        let prepareDistance = min(1_200, max(250, speedMetresPerSecond * 18))
        if safetyDistance <= prepareDistance { return .prepare }
        let earlyDistance = min(3_000, max(500, speedMetresPerSecond * 45))
        if safetyDistance <= earlyDistance { return .early }
        return nil
    }
}

enum NavigationChainedManeuverPolicy {
    static let maximumFollowingDistance: CLLocationDistance = 450

    static func maximumFollowingDistance(speedMetresPerSecond: Double?)
        -> CLLocationDistance {
        guard let speedMetresPerSecond, speedMetresPerSecond.isFinite,
              speedMetresPerSecond >= 0 else { return maximumFollowingDistance }
        // Roughly fourteen seconds of lane-planning time, bounded so an urban
        // "Danach" is not spoken a minute early and motorway combinations are
        // still available early enough at high speed.
        return min(900, max(150, speedMetresPerSecond * 14))
    }

    static func shouldIncludeFollowingManeuver(
        at stage: NavigationAnnouncementStage,
        followingDistance: CLLocationDistance?,
        speedMetresPerSecond: Double? = nil
    ) -> Bool {
        guard stage == .final || stage == .now,
              let followingDistance, followingDistance.isFinite,
              followingDistance >= 0 else { return false }
        return followingDistance <= maximumFollowingDistance(
            speedMetresPerSecond: speedMetresPerSecond
        )
    }
}

enum NavigationTransitionRecoverySpeechPolicy {
    static func shouldChainFollowingManeuver(
        distance: CLLocationDistance,
        speedMetresPerSecond: Double
    ) -> Bool {
        distance.isFinite && distance >= 0 &&
            distance <= NavigationChainedManeuverPolicy.maximumFollowingDistance(
                speedMetresPerSecond: speedMetresPerSecond
            )
    }

    static func text(previousInstruction: String,
                     nextInstruction: String,
                     nextDistance: CLLocationDistance,
                     speedMetresPerSecond: Double) -> String {
        let maximumDistance = NavigationChainedManeuverPolicy.maximumFollowingDistance(
            speedMetresPerSecond: speedMetresPerSecond
        )
        return NavigationSpeechFormatter.spokenText(
            previousInstruction,
            distance: 0,
            then: nextInstruction,
            followingDistance: nextDistance,
            maximumFollowingDistance: maximumDistance
        )
    }
}

enum NavigationManeuverSpeechPolicy {
    static func text(instruction: String, distance: CLLocationDistance,
                     stage: NavigationAnnouncementStage,
                     followingInstruction: String?,
                     followingDistance: CLLocationDistance?,
                     speedMetresPerSecond: Double? = nil) -> String {
        let spokenDistance = stage == .now ? min(distance, 35) : distance
        let followingLimit = NavigationChainedManeuverPolicy.maximumFollowingDistance(
            speedMetresPerSecond: speedMetresPerSecond
        )
        guard NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: stage, followingDistance: followingDistance,
            speedMetresPerSecond: speedMetresPerSecond
        ) else {
            return NavigationSpeechFormatter.spokenText(instruction, distance: spokenDistance)
        }
        return NavigationSpeechFormatter.spokenText(
            instruction, distance: spokenDistance,
            then: followingInstruction, followingDistance: followingDistance,
            maximumFollowingDistance: followingLimit
        )
    }
}

enum NavigationSpeechPriority: Int, Equatable {
    case status
    case maneuver
    case critical

    static func forAnnouncementStage(_ stage: NavigationAnnouncementStage) -> Self {
        // The final distance cue is already decisive guidance, not merely a
        // preparation. Protect the complete sentence just like the immediate
        // cue so a close following exit cannot cut it off halfway through.
        stage == .final || stage == .now ? .critical : .maneuver
    }
}

enum NavigationRerouteStatusSpeechPolicy {
    /// Repeated provider failures can start several recovery attempts while
    /// the visual banner already explains the state. Keep spoken status calm;
    /// maneuver and critical speech use separate priorities and are unaffected.
    static let minimumInterval: TimeInterval = 120

    static func shouldAnnounce(lastAnnouncement: Date?, now: Date = Date()) -> Bool {
        guard let lastAnnouncement else { return true }
        let elapsed = now.timeIntervalSince(lastAnnouncement)
        return elapsed < 0 || elapsed >= minimumInterval
    }
}

enum NavigationSpeechFailureDeduplicationPolicy {
    static func key(maneuverKey: String, stage: NavigationAnnouncementStage) -> String {
        "\(maneuverKey)|\(stage.rawValue)"
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

    /// `didStart` is advisory and can be lost while iOS changes the audio
    /// route (Bluetooth, CarPlay, Siri). A later `didFinish` is still proof
    /// that the utterance completed, so retain the queued claim as a fallback
    /// instead of repeating the same turn on every following GPS fix.
    static func completedClaims<Value>(active: Value?, queued: Value?) -> Value? {
        active ?? queued
    }

    /// Audio callbacks are expected in order, but Bluetooth route changes and
    /// synthesizer interruption can occasionally deliver an older completion
    /// after a newer decisive cue. Delivery state is monotonic: completing an
    /// early stage can never remove an already completed final/now stage.
    static func committedStages(delivered: Set<NavigationAnnouncementStage>,
                                completing stage: NavigationAnnouncementStage)
        -> Set<NavigationAnnouncementStage> {
        delivered.union(stages(upTo: stage))
    }
}

enum NavigationSpeechClaimTimeoutPolicy {
    static let pendingTimeout: TimeInterval = 4
    static let activeTimeout: TimeInterval = 20

    static func isExpired(issuedAt: Date, now: Date, active: Bool) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        // A wall-clock rollback invalidates the timeout basis. Keeping a
        // claim whose issue time now lies in the future can block that
        // maneuver indefinitely if AVSpeechSynthesizer also lost its callback.
        // Expire it so the current GPS fix can safely queue fresh wording.
        guard age >= 0 else { return true }
        return age >= (active ? activeTimeout : pendingTimeout)
    }
}

enum NavigationSpeechInterruptionPolicy {
    static func hasActiveWork(isSpeaking: Bool, hasQueuedUtterance: Bool) -> Bool {
        isSpeaking || hasQueuedUtterance
    }

    static func shouldInterrupt(active: NavigationSpeechPriority,
                                incoming: NavigationSpeechPriority) -> Bool {
        // Never cut one decisive final/"Jetzt" cue in half with the next one
        // at a tight interchange. The second maneuver remains unclaimed and
        // is retried as soon as the speech channel is free; the first sentence
        // often already contains its "Danach" preview. Route replacement and
        // confirmed departure use their explicit cancellation paths instead.
        if active == .critical && incoming == .critical { return false }
        return incoming.rawValue >= active.rawValue
    }

    /// At compact junctions a `.final` cue for the road just left can still
    /// be playing when the next maneuver has already entered its immediate
    /// zone. Both are nominally critical, but the current `.now` instruction
    /// is the only safe one to prioritise. Never preempt an active `.now` cue
    /// or an utterance that already chains the incoming maneuver.
    static func shouldPreemptCriticalFinalCue(
        activeKeys: Set<String>,
        activeStages: Set<NavigationAnnouncementStage>,
        incomingKeys: Set<String>,
        incomingStages: Set<NavigationAnnouncementStage>
    ) -> Bool {
        guard incomingStages.contains(.now), !activeStages.contains(.now) else { return false }
        return !activeKeys.isEmpty && activeKeys.isDisjoint(with: incomingKeys)
    }

    /// A newer distance stage for the same turn must not cut a sentence in
    /// half. Keep it retryable until the audible sentence finishes. Only the
    /// immediate, critical cue may overtake older preparation for that turn.
    static func shouldDeferForSameManeuver(
        activeKeys: Set<String>,
        incomingKeys: Set<String>,
        incomingPriority: NavigationSpeechPriority
    ) -> Bool {
        guard incomingPriority != .critical else { return false }
        return !activeKeys.isDisjoint(with: incomingKeys)
    }

    /// Once a replacement route is committed, every queued or audible
    /// maneuver belongs to geometry that is no longer authoritative. Even a
    /// critical final cue must be cancelled instead of directing the driver
    /// onto the superseded route.
    static func shouldCancelForRouteReplacement(navigationActive: Bool,
                                                hasSpeechWork: Bool) -> Bool {
        navigationActive && hasSpeechWork
    }

    static func shouldCancelForConfirmedDeviation(confirmedOffRoute: Bool,
                                                   navigationActive: Bool,
                                                   hasSpeechWork: Bool) -> Bool {
        confirmedOffRoute && navigationActive && hasSpeechWork
    }

    static func shouldRetryManeuverAfterInterruption(
        navigationActive: Bool,
        voiceGuidance: Bool,
        guidanceReliable: Bool,
        hasUsableLocation: Bool
    ) -> Bool {
        navigationActive && voiceGuidance && guidanceReliable && hasUsableLocation
    }

    /// iOS can end an interruption before the competing call/Siri session has
    /// actually released audio. Retry immediately only when the system marks
    /// the session resumable; otherwise the next location fix makes a fresh,
    /// explicit activation attempt without falsely claiming delivery.
    static func shouldRetryImmediately(systemAllowsResume: Bool) -> Bool {
        systemAllowsResume
    }
}

enum NavigationSpeechCancellationPolicy {
    /// AVSpeechSynthesizer can cancel an utterance when Bluetooth or the audio
    /// route changes without delivering a matching interruption notification.
    /// Retry only an actual maneuver claim; app-initiated cancellation clears
    /// its claims before stopping the synthesizer and therefore stays silent.
    static func shouldRetryUnexpectedCancellation(
        hadManeuverClaim: Bool,
        navigationActive: Bool,
        voiceGuidance: Bool,
        guidanceReliable: Bool,
        hasUsableLocation: Bool
    ) -> Bool {
        hadManeuverClaim && NavigationSpeechInterruptionPolicy
            .shouldRetryManeuverAfterInterruption(
                navigationActive: navigationActive,
                voiceGuidance: voiceGuidance,
                guidanceReliable: guidanceReliable,
                hasUsableLocation: hasUsableLocation
            )
    }
}

enum NavigationSpeechRetryLocationPolicy {
    /// Replaying a maneuver after a call or Bluetooth interruption needs a
    /// much fresher fix than ordinary map presentation. At motorway speed a
    /// twenty-second-old sample can be more than a kilometre behind the car.
    static let maximumAge: TimeInterval = 5
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 65

    static func mayRetry(using location: CLLocation, now: Date = Date()) -> Bool {
        location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy <= maximumHorizontalAccuracy &&
            NavigationLocationPolicy.accepts(
                location, after: nil, now: now, maximumAge: maximumAge
            )
    }
}

struct NavigationInitialManeuver: Equatable {
    let stepIndex: Int
    let instruction: String
    let distance: CLLocationDistance
    let upcomingInstructions: [String]
    let followingManeuverDistance: CLLocationDistance?
}

enum CarPlayManeuverIdentityPolicy {
    static func live(legIndex: Int, stepIndex: Int) -> String {
        "live:\(legIndex):\(stepIndex)"
    }

    static func offline(stepIndex: Int) -> String {
        "offline:\(stepIndex)"
    }
}

enum NavigationInstructionSequencePolicy {
    /// MapKit can repeat a leg-boundary instruction as the first instruction
    /// of the following leg. Hide only adjacent duplicates so a genuinely
    /// repeated maneuver later in the route remains visible.
    static func removingConsecutiveDuplicates(_ instructions: [String]) -> [String] {
        instructions.reduce(into: []) { result, instruction in
            let cleaned = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            guard result.last.map(identity) != identity(cleaned) else { return }
            result.append(cleaned)
        }
    }

    static func firstDistinctInstructionIndex(in instructions: [String], after index: Int) -> Int? {
        guard instructions.indices.contains(index) else { return nil }
        let current = identity(instructions[index])
        return instructions.indices.dropFirst(index + 1).first { candidateIndex in
            let candidate = instructions[candidateIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !candidate.isEmpty && identity(candidate) != current
        }
    }

    /// MapKit can spell the same road differently at a leg boundary (for
    /// example "A66", "A 66" or a trailing full stop). Compare semantic
    /// letters/numbers while retaining the original sentence for display and
    /// speech.
    static func identity(_ instruction: String) -> String {
        let folded = instruction.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}

enum CarPlayGuidancePresentationPolicy {
    /// CarPlay maneuver objects are expensive presentation state. Rebuild
    /// them only from real route instructions; transient spoken status text
    /// such as "Route wird neu berechnet" must never become a turn card.
    static func instructions(upcoming: [String], next: String?,
                             guidanceReliable: Bool = true) -> [String] {
        guard guidanceReliable else { return [] }
        let cleanedUpcoming = NavigationInstructionSequencePolicy
            .removingConsecutiveDuplicates(upcoming)
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

enum CarPlayManeuverEstimatePolicy {
    /// Missing geometry means the distance is unknown, not zero metres. A
    /// fabricated zero makes CarPlay present "Route folgen" like an immediate
    /// turn. Preserve a real zero only for an explicit reached maneuver.
    static func distance(_ value: CLLocationDistance?) -> CLLocationDistance? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

enum CarPlayRouteRecoveryPresentationState: Equatable {
    case normal
    case matchingPosition
    case searching
    case unavailable
}

enum CarPlayRouteRecoveryPresentationPolicy {
    /// Old maneuver cards are deliberately removed after a confirmed route
    /// departure. CarPlay still needs an explicit, non-directional explanation
    /// so an empty dashboard does not look like guidance silently stopped.
    static func state(recalculating: Bool,
                      guidanceReliable: Bool,
                      matchingPosition: Bool = false) -> CarPlayRouteRecoveryPresentationState {
        if matchingPosition { return .matchingPosition }
        if recalculating { return .searching }
        return guidanceReliable ? .normal : .unavailable
    }

    static func titleVariants(for state: CarPlayRouteRecoveryPresentationState) -> [String] {
        switch state {
        case .normal:
            return []
        case .matchingPosition:
            return ["Position wird bestimmt", "Gespeicherte Route wird abgeglichen"]
        case .searching:
            return ["Neue Route wird gesucht", "Route wird neu berechnet"]
        case .unavailable:
            return ["Route verlassen – bitte sicher weiterfahren", "Neuberechnung derzeit nicht möglich"]
        }
    }
}

enum CarPlayTripStartPolicy {
    /// `activateDestination` can already have started local guidance before
    /// CarPlay delivers its `startedTrip` delegate callback. Starting again
    /// would reset maneuver delivery, diagnostics and the navigation session.
    static func shouldStartNavigation(isNavigating: Bool) -> Bool {
        !isNavigating
    }
}

enum CarPlayConnectionWorkPolicy {
    /// Async restoration belongs to the exact head-unit connection that
    /// started it. A reconnect can reuse the same scene delegate while every
    /// CarPlay template from the previous connection is already invalid.
    static func mayPublish(request: UUID, current: UUID, connected: Bool) -> Bool {
        connected && request == current
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
        let followingIndex = NavigationInstructionSequencePolicy.firstDistinctInstructionIndex(
            in: steps.map(\.instruction), after: maneuverIndex
        )
        let followingDistance = followingIndex.map { index in
            steps[maneuverIndex..<index].reduce(0) { $0 + max(0, $1.distance) }
        }
        return .init(
            stepIndex: maneuverIndex,
            instruction: steps[maneuverIndex].instruction,
            distance: distance,
            upcomingInstructions: Array(NavigationInstructionSequencePolicy
                .removingConsecutiveDuplicates(upcoming).prefix(5)),
            followingManeuverDistance: followingDistance
        )
    }
}

enum ManeuverDiagnosticPolicy {
    enum ClosureReason {
        case routeTransition
        case recoveryQueued
        case arrival
        case userStopped
    }

    static func missedFinalCue(stages: Set<NavigationAnnouncementStage>) -> Bool {
        !deliveredDecisiveCue(stages: stages)
    }

    /// A completed final distance cue is already actionable. Repeating that
    /// maneuver only after the route cursor crossed the junction would be too
    /// late and can mislead at closely spaced intersections.
    static func deliveredDecisiveCue(stages: Set<NavigationAnnouncementStage>) -> Bool {
        stages.contains(.final) || stages.contains(.now)
    }

    static func shouldRecordMissedFinalCue(stages: Set<NavigationAnnouncementStage>,
                                           reason: ClosureReason) -> Bool {
        guard reason != .userStopped, reason != .recoveryQueued else { return false }
        return missedFinalCue(stages: stages)
    }

    /// A sparse location update can move directly from the road before a
    /// junction onto the road after it. In that case the final cue must be
    /// recovered once instead of silently disappearing with the old step.
    /// Route replacements clear the previous key before publishing their new
    /// steps, so this applies only to a genuine in-route maneuver transition.
    static func shouldRecoverFinalCue(previousKey: String?, nextKey: String,
                                      stages: Set<NavigationAnnouncementStage>,
                                      inFlightStages: Set<NavigationAnnouncementStage> = [],
                                      previousDistance: CLLocationDistance = 0,
                                      speedMetresPerSecond: Double = 0,
                                      recoveredAfterLocationGap: Bool = false) -> Bool {
        guard let previousKey, previousKey != nextKey else { return false }
        // After a tunnel/background gap the previous junction may be far
        // behind even if the last pre-gap fix was inside its immediate zone.
        // A late "Jetzt" would direct the driver back onto an old road.
        guard !recoveredAfterLocationGap else { return false }
        // A late "Jetzt" is safe only when the last trustworthy fix already
        // placed the vehicle immediately at that junction. If the last known
        // distance was larger, the cursor transition is evidence that the
        // maneuver is behind us; speaking it now could send the driver back
        // onto the abandoned road. The regular announcement path will speak
        // the new current maneuver instead.
        let immediateDistance = min(100, max(30, max(0, speedMetresPerSecond) * 2))
        guard previousDistance.isFinite, previousDistance >= 0,
              previousDistance <= immediateDistance else { return false }
        // An immediate cue can still be playing while the first GPS fix on
        // the road after the junction arrives. Treat that cue as decisive for
        // transition purposes: interrupting it with a second, late "Jetzt"
        // would repeat the turn behind the driver and can be actively unsafe.
        return !deliveredDecisiveCue(stages: stages.union(inFlightStages))
    }
}

/// Resolves the last maneuver when MapKit advances directly onto the final
/// road. There is no following maneuver object to drive the normal transition
/// path, but silently dropping the outstanding turn is just as unsafe as
/// repeating it after a tunnel or background gap.
enum NavigationFinalRoadTransitionPolicy {
    enum Action: Equatable {
        case none
        case recoverNow
        case closeAsDelivered
        case closeAsMissed
    }

    static func action(previousKey: String?, delivered: Set<NavigationAnnouncementStage>,
                       inFlight: Set<NavigationAnnouncementStage>,
                       previousDistance: CLLocationDistance?,
                       speedMetresPerSecond: Double,
                       recoveredAfterLocationGap: Bool) -> Action {
        guard let previousKey else { return .none }
        let decisive = delivered.union(inFlight)
        if ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: decisive) {
            return .closeAsDelivered
        }
        if ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: previousKey,
            nextKey: "final-road",
            stages: delivered,
            inFlightStages: inFlight,
            previousDistance: previousDistance ?? .greatestFiniteMagnitude,
            speedMetresPerSecond: speedMetresPerSecond,
            recoveredAfterLocationGap: recoveredAfterLocationGap
        ) {
            return .recoverNow
        }
        return .closeAsMissed
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

enum NavigationLocationDiagnosticPolicy {
    static let minimumLogInterval: TimeInterval = 20

    static func shouldLog(lastLoggedAt: Date?, now: Date) -> Bool {
        guard let lastLoggedAt else { return true }
        let elapsed = now.timeIntervalSince(lastLoggedAt)
        return elapsed < 0 || elapsed >= minimumLogInterval
    }
}

/// A long background/tunnel gap can move the car farther than the bounded
/// live step window. Permit one full forward match only when both time and
/// displacement prove that ordinary sequential advancement cannot catch up.
/// The step selector still requires plausible route course and never moves
/// backwards, so a nearby crossing cannot rewind the trip.
enum NavigationLiveRecoveryPolicy {
    static let minimumGap: TimeInterval = 90
    static let minimumDisplacement: CLLocationDistance = 2_000

    static func allowsFullRouteMatch(previous: CLLocation?, current: CLLocation) -> Bool {
        guard let previous else { return false }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed >= minimumGap else { return false }
        return current.distance(from: previous) >= minimumDisplacement
    }
}

enum NavigationLocationGapPolicy {
    static let minimumGap: TimeInterval = 30

    static func recoveredGap(previous: CLLocation?, current: CLLocation) -> TimeInterval? {
        guard let previous else { return nil }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed.isFinite, elapsed >= minimumGap else { return nil }
        return elapsed
    }
}

/// Live navigation state changes on every accepted GPS fix, but encoding and
/// writing several UserDefaults payloads at that same cadence can stall map
/// rendering on long drives. A short checkpoint interval retains useful crash
/// recovery without turning every location callback into synchronous I/O.
enum NavigationPersistenceCheckpointPolicy {
    static let interval: TimeInterval = 30

    static func shouldPersist(
        last: Date?, now: Date,
        interval: TimeInterval = NavigationPersistenceCheckpointPolicy.interval
    ) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= max(0, interval)
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
                guard sameTimestamp else {
                    result.append(candidate)
                    return
                }
                // Some providers refine a fix in place and may adjust both
                // its accuracy and coordinate without changing its timestamp.
                // Guidance can consume only one sample at a given instant, so
                // keep the useful, tighter fix instead of allowing delivery
                // order to decide which side of a junction wins.
                if candidate.horizontalAccuracy >= 0 &&
                    (previous.horizontalAccuracy < 0 ||
                     candidate.horizontalAccuracy < previous.horizontalAccuracy) {
                    result[result.count - 1] = candidate
                }
            }
    }

    /// Returns the chronological portion of a delivered batch ending at its
    /// newest live, plausible fix. Core Location occasionally appends one
    /// coarse or displaced measurement after several useful fixes. Dropping
    /// the entire batch in that case freezes the map and can hide a maneuver;
    /// consuming values after the bad endpoint would be equally unsafe.
    static func freshGuidanceBatch(
        _ locations: [CLLocation],
        after previous: CLLocation?,
        now: Date
    ) -> [CLLocation] {
        let ordered = orderedDistinct(locations)
        guard let endpoint = ordered.lastIndex(where: {
            NavigationLocationPolicy.accepts($0, after: previous, now: now)
        }) else { return [] }
        // Validate the selected prefix as one physical journey. A point can
        // look plausible relative to the pre-tunnel fix but become an
        // impossible backwards jump after a newer accepted intermediate fix.
        // Conversely, one corrupt intermediate sample must not poison a good
        // current endpoint, so invalid values are skipped rather than ending
        // the batch. Buffered history may be older than a normal live fix,
        // but the final published value must still be live now.
        var accepted: [CLLocation] = []
        var lastAccepted = previous
        for candidate in ordered[...endpoint] where NavigationLocationPolicy.accepts(
            candidate, after: lastAccepted, now: now,
            maximumAge: maximumBufferedSampleAge
        ) {
            accepted.append(candidate)
            lastAccepted = candidate
        }
        guard let latest = accepted.last,
              NavigationLocationPolicy.accepts(latest, after: nil, now: now)
        else { return [] }
        return accepted
    }
}

enum NavigationBatchReroutePolicy {
    /// Buffered fixes are still consumed in order so maneuver progress is not
    /// lost after a tunnel or background suspension. Only the newest accepted
    /// fix may start network rerouting: an older noisy point must not launch a
    /// replacement route before the batch's current endpoint proves that the
    /// vehicle has already rejoined the planned road.
    static func mayStartAutomaticReroute(sampleIndex: Int, sampleCount: Int) -> Bool {
        sampleCount > 0 && sampleIndex == sampleCount - 1
    }
}

enum CarPlayCameraUpdatePolicy {
    /// CarPlay can receive navigation fixes substantially faster than its map
    /// surface can animate cameras. Starting a new animation for every 8 m
    /// location update queues motion behind the vehicle at motorway speed.
    static let minimumInterval: TimeInterval = 0.2

    static func shouldUpdate(last: Date?, current: Date,
                             minimumInterval: TimeInterval = minimumInterval) -> Bool {
        guard let last else { return true }
        let elapsed = current.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= max(0, minimumInterval)
    }
}

enum CarPlayCameraMode: Equatable {
    case follow, overview, free
}

enum CarPlayCameraLifecyclePolicy {
    /// A newly connected dashboard must always start by following the car.
    /// Retaining a manual pan from the previous cable/wireless session leaves
    /// the map stranded while the driver is already moving.
    static func modeAfterConnection(previous: CarPlayCameraMode) -> CarPlayCameraMode {
        .follow
    }

    /// Starting a new trip is an explicit navigation action and must bring
    /// the driving camera back to the car. Ordinary route publications while
    /// a trip is already active retain `.free`/`.overview`, so live reroutes
    /// never fight a deliberate pan or zoom.
    static func mode(previous: CarPlayCameraMode,
                     navigationWasActive: Bool,
                     navigationIsActive: Bool) -> CarPlayCameraMode {
        !navigationWasActive && navigationIsActive ? .follow : previous
    }
}

enum CarPlayRouteLinePolicy {
    /// A seven-point route is easy to follow in the driving camera but hides
    /// junction geometry and even small towns in the full-trip overview.
    /// Keep the overview legible without making active guidance look faint.
    static func width(isOverview: Bool) -> CGFloat {
        isOverview ? 4.5 : 7
    }
}

enum RouteOverviewMapRectPolicy {
    /// Reject a wildly displaced GPS fix before it becomes part of the full
    /// route overview. A restored route can briefly receive a cached or
    /// network-derived location from another region; fitting that point would
    /// make the actual journey look like a single pixel. Genuine deviations
    /// remain visible within the generous corridor.
    static func vehicleCoordinate(_ coordinate: CLLocationCoordinate2D?,
                                  near base: MKMapRect?,
                                  maximumDistanceMetres: CLLocationDistance = 100_000)
        -> CLLocationCoordinate2D? {
        guard let coordinate, isValid(coordinate) else { return nil }
        guard let base, !base.isNull, !base.isEmpty else { return coordinate }
        let point = MKMapPoint(coordinate)
        let dx = max(base.minX - point.x, 0, point.x - base.maxX)
        let dy = max(base.minY - point.y, 0, point.y - base.maxY)
        let mapPointDistance = hypot(dx, dy)
        let metres = mapPointDistance / MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        return metres <= max(0, maximumDistanceMetres) ? coordinate : nil
    }

    static func including(_ base: MKMapRect?,
                          coordinates: [CLLocationCoordinate2D]) -> MKMapRect? {
        var rect = base ?? .null
        for coordinate in coordinates where isValid(coordinate) {
            let point = MKMapPoint(coordinate)
            // A tiny non-zero rect reliably participates in MapKit unions;
            // zero-sized point rects can be discarded at an existing edge.
            rect = rect.union(MKMapRect(x: point.x - 0.5, y: point.y - 0.5,
                                        width: 1, height: 1))
        }
        return rect.isNull ? nil : rect
    }

    private static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
            (-90...90).contains(coordinate.latitude) &&
            (-180...180).contains(coordinate.longitude)
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

/// Presentation boundary for the live speed badge. Core Location can retain
/// its last sample while the app is briefly backgrounded or GPS reception is
/// lost. Showing that value as the current speed would be more misleading
/// than hiding it, especially next to a legal speed-limit sign.
enum NavigationSpeedDisplayPolicy {
    static let maximumAge: TimeInterval = 5

    static func speedKilometresPerHour(
        for location: CLLocation?, now: Date = Date()
    ) -> Int? {
        guard let location,
              abs(location.timestamp.timeIntervalSince(now)) <= maximumAge,
              let metresPerSecond = NavigationMotionPolicy.reliableSpeed(for: location)
        else { return nil }
        return Int((metresPerSecond * 3.6).rounded())
    }
}

/// Keeps the driver's marker low in the navigation viewport and exposes more
/// of the road ahead as speed increases. Fixed zoom and a coordinate centered
/// exactly on the car hide motorway exits until they are unnecessarily close.
enum NavigationFollowCameraPolicy {
    static func distance(speedMetresPerSecond speed: Double?) -> CLLocationDistance {
        let value = max(0, speed ?? 0)
        return min(1_400, max(700, 650 + value * 18))
    }

    static func lookAheadDistance(speedMetresPerSecond speed: Double?) -> CLLocationDistance {
        let value = max(0, speed ?? 0)
        guard value >= 2.5 else { return 0 }
        return min(450, max(90, value * 9))
    }

    static func center(from coordinate: CLLocationCoordinate2D,
                       headingDegrees: Double,
                       speedMetresPerSecond: Double?) -> CLLocationCoordinate2D {
        let metres = lookAheadDistance(speedMetresPerSecond: speedMetresPerSecond)
        guard metres > 0, headingDegrees.isFinite else { return coordinate }
        let radius = 6_371_000.0
        let angularDistance = metres / radius
        let bearing = headingDegrees * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let projectedLatitude = asin(
            sin(latitude) * cos(angularDistance) +
            cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let projectedLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(projectedLatitude)
        )
        return .init(latitude: projectedLatitude * 180 / .pi,
                     longitude: projectedLongitude * 180 / .pi)
    }
}

/// Keeps announcement timing stable when Core Location temporarily publishes
/// an invalid speed (common after tunnels, background resumes and CarPlay
/// reconnects). A short-lived last trustworthy value is safer than suddenly
/// shrinking a motorway warning horizon to the stationary fallback.
enum NavigationGuidanceSpeedPolicy {
    static let retention: TimeInterval = 20
    static let fallbackMetresPerSecond = 13.9 // roughly 50 km/h
    static let maximumGuidanceDeceleration = 3.0

    static func effective(current: Double?, previous: Double?, previousAt: Date?,
                          now: Date) -> Double {
        if let current {
            guard let previous, let previousAt else { return current }
            let elapsed = now.timeIntervalSince(previousAt)
            guard elapsed >= 0, elapsed <= retention else { return current }
            // A single noisy fix or braking wave before a motorway exit must
            // not collapse the warning horizon from motorway to city timing.
            // Follow genuine deceleration quickly, but limit the rate at
            // which guidance timing shrinks. Persisting this effective value
            // makes the reduction continuous over subsequent fixes.
            let decayedPrevious = max(
                0, previous - maximumGuidanceDeceleration * elapsed
            )
            return max(current, decayedPrevious)
        }
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
    static let requiredStableDuration: TimeInterval = 4
    static let maximumRemainingRouteDistance: CLLocationDistance = 250

    static func mayCompleteTrip(hasOpenRequiredWaypoints: Bool,
                                guidanceReliable: Bool = true,
                                recalculating: Bool = false,
                                remainingRouteDistance: CLLocationDistance = 0) -> Bool {
        !hasOpenRequiredWaypoints && guidanceReliable && !recalculating &&
            remainingRouteDistance.isFinite && remainingRouteDistance >= 0 &&
            remainingRouteDistance <= maximumRemainingRouteDistance
    }

    static func isArrivalFix(_ location: CLLocation, destination: CLLocationCoordinate2D) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return false }
        let speed = location.speed < 0 ? 0 : location.speed
        guard speed <= 8.33 else { return false } // below roughly 30 km/h
        let radius = max(35, location.horizontalAccuracy * 1.5)
        return location.distance(from: CLLocation(latitude: destination.latitude,
                                                  longitude: destination.longitude)) <= radius
    }

    static func hasSettled(since firstFix: Date?, at currentFix: Date) -> Bool {
        guard let firstFix else { return false }
        let duration = currentFix.timeIntervalSince(firstFix)
        return duration >= requiredStableDuration
    }
}

struct NavigationStepMetric: Equatable {
    let distanceFromRoute: CLLocationDistance
    let remainingOnStep: CLLocationDistance
    let stepDistance: CLLocationDistance
    let hasUsableGeometry: Bool
    /// Geometry-free steps containing a real instruction must not be skipped.
    let hasManeuverInstruction: Bool
    /// Difference between the car's trustworthy course and the local route
    /// segment. `nil` deliberately keeps distance-only matching while stopped
    /// or when Core Location cannot provide a useful course.
    let courseDifferenceDegrees: Double?

    init(distanceFromRoute: CLLocationDistance, remainingOnStep: CLLocationDistance,
         stepDistance: CLLocationDistance = 0,
         courseDifferenceDegrees: Double? = nil,
         hasUsableGeometry: Bool = true,
         hasManeuverInstruction: Bool = false) {
        self.distanceFromRoute = distanceFromRoute
        self.remainingOnStep = remainingOnStep
        self.stepDistance = stepDistance
        self.courseDifferenceDegrees = courseDifferenceDegrees
        self.hasUsableGeometry = hasUsableGeometry
        self.hasManeuverInstruction = hasManeuverInstruction
    }
}

/// Distance alone cannot distinguish two carriageways, a flyover, or the
/// parallel motorway and exit ramp at a junction. A live, reliable vehicle
/// course gives us the missing direction without making guidance dependent on
/// a compass while the car is stationary.
enum NavigationCourseMatchingPolicy {
    static let maximumPlausibleDifference = 80.0
    /// MapKit occasionally repeats a coordinate at step boundaries. Such a
    /// zero-length segment has no direction and must not disable course
    /// matching exactly where carriageways and ramps are closest together.
    static let minimumDirectionalSegmentLength: CLLocationDistance = 1

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
            guard points[index].distance(to: points[index + 1]) >=
                    minimumDirectionalSegmentLength else { continue }
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

    static func metricEvaluationIndices(current: Int, stepCount: Int) -> Range<Int> {
        guard stepCount > 0 else { return 0..<0 }
        let cursor = min(max(0, current), stepCount - 1)
        return cursor..<min(stepCount, cursor + maximumMeasuredRecoveryStepAdvance + 1)
    }

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
        let protectedManeuverBoundary = metrics.indices.dropFirst(current).first(where: {
            !metrics[$0].hasUsableGeometry && metrics[$0].hasManeuverInstruction
        })
        let recoveryCandidateIsSafe: (Int) -> Bool = { index in
            // Full recovery is used only after a verified long location gap
            // or for the initial match of a restored offline trip. The car
            // may legitimately already be beyond an instruction-only marker;
            // keeping that marker as an absolute wall would prevent the route
            // from ever resuming. Ordinary continuous updates retain the wall
            // and cross it only through the junction evidence below.
            if allowsFullRecovery { return true }
            return protectedManeuverBoundary.map { index <= $0 } ?? true
        }

        // Only the first fix of a restored offline route may search the whole
        // remaining journey. Prefer the earliest plausible road segment over
        // a microscopically closer later crossing, so loops and cloverleafs do
        // not skip required sections. Normal live updates keep the tight
        // forward window below.
        let currentCourseIsPlausible = NavigationCourseMatchingPolicy.isPlausible(
            metrics[current].courseDifferenceDegrees
        )
        if allowsFullRecovery,
           metrics[current].distanceFromRoute > 250 || !currentCourseIsPlausible {
            if let earliestPlausible = metrics.indices.dropFirst(current).first(where: {
                recoveryCandidateIsSafe($0) &&
                    metrics[$0].distanceFromRoute <= max(45, radius * 1.5) &&
                    NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }) {
                return earliestPlausible
            }
            if metrics[current].hasUsableGeometry,
               let nearest = metrics.indices.dropFirst(current).filter({
                recoveryCandidateIsSafe($0) &&
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
                recoveryCandidateIsSafe($0) &&
                    metrics[$0].distanceFromRoute <= max(45, radius * 1.5) &&
                    NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }) {
                return earliestPlausible
            }
            if metrics[current].hasUsableGeometry,
               let recovered = recovery.filter({
                recoveryCandidateIsSafe($0) &&
                    NavigationCourseMatchingPolicy.isPlausible(metrics[$0].courseDifferenceDegrees)
            }).min(by: {
                metrics[$0].distanceFromRoute < metrics[$1].distanceFromRoute
            }), metrics[recovered].distanceFromRoute + 80 < metrics[current].distanceFromRoute {
                return recovered
            }
        }

        var selected = current
        var crossedManeuverBoundary = false
        while metrics.indices.contains(selected + 1) {
            let active = metrics[selected]
            var successorIndex = selected + 1
            if !active.hasUsableGeometry,
               active.stepDistance <= 0,
               !active.hasManeuverInstruction {
                while metrics.indices.contains(successorIndex),
                      !metrics[successorIndex].hasUsableGeometry,
                      metrics[successorIndex].stepDistance <= 0,
                      !metrics[successorIndex].hasManeuverInstruction {
                    successorIndex += 1
                }
            }
            guard metrics.indices.contains(successorIndex) else { break }
            let next = metrics[successorIndex]
            // One ordinary Core Location fix must not consume two real turns.
            // At compact junctions both short outgoing geometries can be within
            // the same 8–15 metre transition radius; advancing across both
            // would replace the second banner and spoken cue before the driver
            // has received it. Buffered fixes are processed individually, and
            // the explicit recovery branches above still catch up after a
            // tunnel or long suspension.
            if crossedManeuverBoundary && next.hasManeuverInstruction &&
                !allowsFullRecovery { break }
            let headingMatches = NavigationCourseMatchingPolicy.isPlausible(
                next.courseDifferenceDegrees
            )
            // Some MapKit routes encode the actual turn as an instruction-only
            // marker with no polyline between the incoming and outgoing road.
            // Keep that marker protected while approaching, but once the car
            // has reached the end of the incoming geometry and is clearly on
            // the road after it, cross the marker atomically. Otherwise the
            // infinite geometry sentinel can freeze guidance at the junction
            // for the rest of the trip.
            if next.hasManeuverInstruction, !next.hasUsableGeometry,
               metrics.indices.contains(successorIndex + 1) {
                let outgoingIndex = successorIndex + 1
                let outgoing = metrics[outgoingIndex]
                let outgoingHeadingMatches = NavigationCourseMatchingPolicy.isPlausible(
                    outgoing.courseDifferenceDegrees
                )
                let reachedInstructionOnlyJunction = active.hasUsableGeometry &&
                    active.remainingOnStep <= radius &&
                    outgoing.hasUsableGeometry &&
                    outgoing.distanceFromRoute <= radius * 1.5 &&
                    outgoingHeadingMatches
                if reachedInstructionOnlyJunction {
                    selected = outgoingIndex
                    crossedManeuverBoundary = true
                    continue
                }
            }
            let reachedJunction = active.remainingOnStep <= radius &&
                next.distanceFromRoute <= radius * 1.5 && headingMatches
            // A parallel ramp can be much closer than the active motorway
            // carriageway while the real exit is still hundreds of metres
            // ahead. Treat the next step as "clearly past" only close to the
            // end of the active step. Larger discontinuities are handled by
            // the explicit recovery path above.
            let nearActiveStepEnd = active.remainingOnStep <= max(120, radius * 4)
            let clearlyPastStep = active.distanceFromRoute > 60 &&
                next.distanceFromRoute + 30 < active.distanceFromRoute &&
                next.distanceFromRoute <= 45 && headingMatches && nearActiveStepEnd
            // MapKit occasionally inserts an empty, zero-distance transition
            // step between two usable roads. It cannot be map-matched and its
            // infinite sentinel values would otherwise freeze the maneuver
            // cursor forever. Advance only onto a nearby, directionally
            // plausible successor; never skip ahead merely because geometry
            // is missing.
            let unusableTransition = !active.hasUsableGeometry &&
                active.stepDistance <= 0 &&
                !active.hasManeuverInstruction &&
                next.distanceFromRoute <= max(45, radius * 1.5) && headingMatches
            guard reachedJunction || clearlyPastStep || unusableTransition else { break }
            if next.hasManeuverInstruction { crossedManeuverBoundary = true }
            selected = unusableTransition ? successorIndex : selected + 1
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
        let speed = max(speedMetresPerSecond, 0)
        let roadBase: Double
        switch speed {
        case ..<12: roadBase = 55   // Stadt: eine echte falsche Abbiegung schnell erkennen
        case ..<22: roadBase = 75   // Landstraße und zäher Autobahnverkehr
        default: roadBase = 100     // Autobahn: Parallelfahrbahnen/GPS-Streuung tolerieren
        }
        return max(roadBase, horizontalAccuracy * 3, min(220, speed * 4))
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
                                 rerouteAllowed: Bool = true,
                                 wrongWay: Bool = false) -> Bool {
        guard rerouteAllowed,
              speedMetresPerSecond >= 2.5 else { return false }
        // Remaining close to the polyline is not proof that the planned route
        // is being followed: the driver may be travelling back along the same
        // carriageway. Course evidence is deliberately produced by the strict
        // policy below and still has to survive the normal multi-fix timer.
        if wrongWay { return true }
        guard isOutsideCorridor(distanceFromRoute: distanceFromRoute,
                                horizontalAccuracy: horizontalAccuracy,
                                speedMetresPerSecond: speedMetresPerSecond) else { return false }
        if let previousDistance, distanceFromRoute + 30 < previousDistance { return false }
        return true
    }

    static func confirmationDuration(speedMetresPerSecond: Double) -> TimeInterval {
        speedMetresPerSecond < 12 ? 6 : 8
    }

    static func isConfirmed(elapsed: TimeInterval, consecutiveFixes: Int,
                            speedMetresPerSecond: Double) -> Bool {
        consecutiveFixes >= requiredConsecutiveFixes &&
            elapsed >= confirmationDuration(speedMetresPerSecond: speedMetresPerSecond)
    }
}

enum NavigationDeviationSequencePolicy {
    /// Location delivery can pause in tunnels, while the app is backgrounded,
    /// or while Core Location recovers. Fixes separated by such a gap are not
    /// evidence of one sustained departure and must start a fresh sequence.
    static let maximumFixGap: TimeInterval = 12

    static func shouldRestart(previousFixAt: Date?, currentFixAt: Date) -> Bool {
        guard let previousFixAt else { return true }
        let gap = currentFixAt.timeIntervalSince(previousFixAt)
        return gap < 0 || gap > maximumFixGap
    }
}

enum NavigationWrongWayPolicy {
    /// Detect driving against the installed route while still sitting directly
    /// on its geometry. A high angular threshold plus a meaningful speed keeps
    /// bends, parking manoeuvres and uncertain Core Location headings out.
    static func isOpposing(courseDifferenceDegrees: Double?,
                           distanceFromRoute: CLLocationDistance,
                           horizontalAccuracy: CLLocationAccuracy,
                           speedMetresPerSecond: Double) -> Bool {
        guard let difference = courseDifferenceDegrees, difference.isFinite,
              difference >= 150,
              distanceFromRoute.isFinite, distanceFromRoute >= 0,
              horizontalAccuracy >= 0, horizontalAccuracy <= 35,
              speedMetresPerSecond >= 5.5 else { return false }
        return distanceFromRoute <= max(30, min(70, horizontalAccuracy * 2))
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

enum NavigationDeviationGeometryPolicy {
    /// An empty MapKit step has no route geometry. Treating its sentinel
    /// distance as a real deviation can start an endless recalculation loop
    /// while a route is being restored or replaced.
    static func nearestUsableDistance(
        _ candidates: [(pointCount: Int, distance: CLLocationDistance)]
    ) -> CLLocationDistance? {
        candidates.compactMap { candidate in
            guard candidate.pointCount > 1, candidate.distance.isFinite,
                  candidate.distance >= 0 else { return nil }
            return candidate.distance
        }.min()
    }

    static func nearestUsableMetric(_ candidates: [NavigationStepMetric])
        -> NavigationStepMetric? {
        candidates.filter {
            $0.hasUsableGeometry && $0.distanceFromRoute.isFinite &&
                $0.distanceFromRoute >= 0
        }.min { $0.distanceFromRoute < $1.distanceFromRoute }
    }
}

enum NavigationManeuverSafetyPolicy {
    static func mayAnnounceLiveManeuver(navigationActive: Bool,
                                        rerouting: Bool,
                                        confirmedOffRoute: Bool) -> Bool {
        navigationActive && !rerouting && !confirmedOffRoute
    }
}

enum NavigationRouteRejoinPolicy {
    // Shared by live and cached guidance. Requiring the same stable sequence
    // prevents offline navigation from reviving stale turns after one noisy
    // snap to a parallel road or route crossing.
    static let requiredConsecutiveInsideFixes = 3

    static func isConfirmed(consecutiveInsideFixes: Int) -> Bool {
        consecutiveInsideFixes >= requiredConsecutiveInsideFixes
    }

    /// Proximity alone cannot prove a rejoin on parallel roads or at a
    /// flyover. Once the car is moving quickly enough for Core Location's
    /// course to be meaningful, the local route direction must agree too.
    /// While stopped or without course data, retain distance-only matching.
    static func acceptsInsideFix(isOutsideCorridor: Bool,
                                 courseDifferenceDegrees: Double?,
                                 speedMetresPerSecond: Double) -> Bool {
        guard !isOutsideCorridor else { return false }
        guard speedMetresPerSecond >= 5.5,
              courseDifferenceDegrees != nil else { return true }
        return NavigationCourseMatchingPolicy.isPlausible(courseDifferenceDegrees)
    }

    /// A slow MapKit request must not replace the original route after the
    /// driver has already returned to it. The same stable-match requirement
    /// used to restore maneuver guidance also owns cancellation of that work.
    static func shouldCancelAutomaticReroute(isRecalculating: Bool,
                                             guidanceReliable: Bool,
                                             consecutiveInsideFixes: Int) -> Bool {
        isRecalculating && !guidanceReliable &&
            isConfirmed(consecutiveInsideFixes: consecutiveInsideFixes)
    }
}

struct NavigationInstructionDisplay: Equatable {
    let instruction: String
    let distance: CLLocationDistance?
    let upcomingInstructions: [String]
    let guidanceUnavailable: Bool
}

enum NavigationInstructionDisplayPolicy {
    /// Once a departure is confirmed, the previous road's maneuver is unsafe
    /// even if MapKit cannot return a replacement route. Keep the map visible,
    /// but replace the stale turn card until route matching is trustworthy.
    static func display(instruction: String?,
                        distance: CLLocationDistance?,
                        upcomingInstructions: [String],
                        guidanceReliable: Bool,
                        recalculating: Bool,
                        matchingPosition: Bool = false) -> NavigationInstructionDisplay {
        if matchingPosition {
            return .init(
                instruction: "Position wird bestimmt", distance: nil,
                upcomingInstructions: [], guidanceUnavailable: true
            )
        }
        guard guidanceReliable else {
            return .init(
                instruction: recalculating ? "Neue Route wird gesucht" : "Route verlassen – sicher weiterfahren",
                distance: nil,
                upcomingInstructions: [],
                guidanceUnavailable: true
            )
        }
        return .init(
            instruction: instruction ?? "Route folgen",
            distance: distance,
            upcomingInstructions: upcomingInstructions,
            guidanceUnavailable: false
        )
    }
}

/// Failed MapKit requests must not turn a genuine deviation into a spoken
/// recalculation loop. Successful reroutes retain the short normal cooldown;
/// repeated failures back off while the old route remains visible.
enum NavigationRerouteRetryPolicy {
    static let meaningfulMovementMetres: CLLocationDistance = 750
    static let movementRetryCooldown: TimeInterval = 20

    static func cooldown(consecutiveFailures: Int) -> TimeInterval {
        switch max(0, consecutiveFailures) {
        case 0: 30
        case 1: 60
        default: 3 * 60
        }
    }

    static func mayRetry(lastAttempt: Date?, consecutiveFailures: Int,
                         distanceSinceAttempt: CLLocationDistance? = nil,
                         now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // Clock corrections and restored system snapshots can make an
        // in-memory attempt appear to lie in the future. Waiting for that
        // timestamp would suppress rerouting exactly when recovery is needed.
        if elapsed < 0 { return true }
        if elapsed >= cooldown(consecutiveFailures: consecutiveFailures) { return true }
        if consecutiveFailures > 0,
           let distanceSinceAttempt, distanceSinceAttempt.isFinite,
           distanceSinceAttempt >= meaningfulMovementMetres,
           elapsed >= movementRetryCooldown {
            return true
        }
        return false
    }

    /// Once a departure was already confirmed, a failed network request must
    /// remain retryable after the normal backoff even if the driver has stopped.
    /// Requiring moving evidence again can strand guidance indefinitely at a
    /// lay-by or junction. This never establishes a new departure: it only
    /// continues recovery while fresh geometry still proves the car is outside.
    static func shouldRetryConfirmedDeparture(
        guidanceReliable: Bool,
        isOutsideCorridor: Bool,
        retryAllowed: Bool,
        consecutiveFailures: Int
    ) -> Bool {
        !guidanceReliable && isOutsideCorridor && retryAllowed && consecutiveFailures > 0
    }
}

/// MapKit normally answers quickly, but an interrupted network request can
/// remain suspended for much longer. The navigation UI must never stay in a
/// permanent "recalculating" state because of one lost response.
enum NavigationRerouteWatchdogPolicy {
    static let timeout: TimeInterval = 20
    static let timeoutNanoseconds: UInt64 = UInt64(timeout * 1_000_000_000)

    static func timeout(legCount: Int) -> TimeInterval {
        timeout * Double(NavigationMultiLegRoutingPolicy.batchCount(for: legCount))
    }

    static func timeoutNanoseconds(legCount: Int) -> UInt64 {
        UInt64(timeout(legCount: legCount) * 1_000_000_000)
    }

    static func hasTimedOut(startedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= timeout
    }
}

enum NavigationMultiLegRoutingPolicy {
    /// Matches the already proven bounded concurrency used by along-route POI
    /// search. Holiday routes no longer wait for every independent MapKit leg
    /// serially, while arbitrary stop lists cannot flood the service.
    static let maximumConcurrentLegs = 5

    static func batches(legCount: Int) -> [Range<Int>] {
        guard legCount > 0 else { return [] }
        return stride(from: 0, to: legCount, by: maximumConcurrentLegs).map { start in
            start..<min(legCount, start + maximumConcurrentLegs)
        }
    }

    static func batchCount(for legCount: Int) -> Int {
        max(1, batches(legCount: legCount).count)
    }
}

enum NavigationRerouteFailureSpeechPolicy {
    static func text(timedOut: Bool) -> String {
        if timedOut {
            return "Die Neuberechnung dauert zu lange. Fahrhinweise sind vorübergehend pausiert. Bitte sicher weiterfahren."
        }
        return "Die Route konnte gerade nicht neu berechnet werden. Fahrhinweise sind vorübergehend pausiert. Bitte sicher weiterfahren."
    }
}

enum NavigationReroutePresentationPolicy {
    /// MapKit can take several seconds to replace a route while the vehicle
    /// keeps moving. Seed the new maneuver card and speech from the newest
    /// accepted fix, never from the location that originally triggered the
    /// request. A clock-skewed older fix must not replace the trigger point.
    static func location(trigger: CLLocation, latest: CLLocation?) -> CLLocation {
        guard let latest,
              latest.timestamp >= trigger.timestamp else { return trigger }
        return latest
    }
}

enum NavigationDirectionsTimeoutPolicy {
    static let routeCalculation: TimeInterval = 18
    static let detourCalculation: TimeInterval = 8

    static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        UInt64(max(0, timeout) * 1_000_000_000)
    }
}

struct NavigationDirectionsTimeoutError: LocalizedError {
    var errorDescription: String? { "Zeitüberschreitung bei der Routenberechnung." }
}

enum OfflineRouteRecoveryPolicy {
    static let retryInterval: TimeInterval = 90
    static let urgentRetryInterval: TimeInterval = 20

    static func shouldAttempt(lastAttempt: Date?, urgent: Bool = false,
                              now: Date = Date()) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        let interval = urgent ? urgentRetryInterval : retryInterval
        return elapsed < 0 || elapsed >= interval
    }

    static func acceptsOnlineResult(calculationSucceeded: Bool,
                                    navigationActive: Bool,
                                    stillUsingOfflineGuidance: Bool) -> Bool {
        calculationSucceeded && navigationActive && !stillUsingOfflineGuidance
    }
}

enum OfflineInitialPositionMatchPolicy {
    static let requiredConsecutiveMatches = 3

    /// The first cached-route match is authoritative only inside the same
    /// accuracy/speed-aware corridor used by deviation detection. A far-away
    /// cached GPS fix must not consume full-route recovery before the first
    /// trustworthy post-launch location arrives.
    static func isReliable(distanceFromRoute: CLLocationDistance,
                           horizontalAccuracy: CLLocationAccuracy,
                           speedMetresPerSecond: Double,
                           wrongWay: Bool = false) -> Bool {
        !wrongWay && !NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: distanceFromRoute,
            horizontalAccuracy: horizontalAccuracy,
            speedMetresPerSecond: speedMetresPerSecond
        )
    }

    static func isConfirmed(consecutiveMatches: Int) -> Bool {
        consecutiveMatches >= requiredConsecutiveMatches
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
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= retryInterval
    }
}

enum RouteRestoreModePolicy {
    enum Mode: Equatable { case online, offline, staleLive, unavailable }

    static func mode(onlineCalculationSucceeded: Bool, hasMatchingLiveRoute: Bool,
                     hasMatchingOfflineRoute: Bool) -> Mode {
        if onlineCalculationSucceeded && hasMatchingLiveRoute { return .online }
        if hasMatchingOfflineRoute { return .offline }
        if hasMatchingLiveRoute { return .staleLive }
        return .unavailable
    }
}

enum ForegroundRouteFallbackPolicy {
    enum Mode: Equatable { case online, matchingLive, offline, unavailable }

    /// A failed foreground request may resume the persisted offline trip only
    /// when no exactly matching live geometry is still usable. Destination,
    /// waypoint and option identity are verified before choosing this mode.
    static func mode(onlineCalculationSucceeded: Bool,
                     hasMatchingLiveRoute: Bool,
                     hasMatchingOfflineRoute: Bool) -> Mode {
        if onlineCalculationSucceeded { return .online }
        if hasMatchingLiveRoute { return .matchingLive }
        if hasMatchingOfflineRoute { return .offline }
        return .unavailable
    }
}

enum LiveRouteRestoreEligibilityPolicy {
    /// Reusing in-memory geometry after an online failure is safe only when it
    /// was calculated for both the same destination and the exact currently
    /// active waypoint/option set. Destination equality alone can silently
    /// bypass a mandatory pass or a segment-specific motorway restriction.
    static func mayReuse(destinationMatches: Bool,
                         installedConstraintIdentity: String?,
                         activeConstraintIdentity: String?) -> Bool {
        guard destinationMatches, let activeConstraintIdentity else { return false }
        return installedConstraintIdentity == activeConstraintIdentity
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

enum DestinationSubtitlePolicy {
    static func subtitle(name: String?, lockedRouteTitle: String?, locality: String?,
                         administrativeArea: String?, country: String?,
                         fallbackTitle: String?) -> String {
        let cleanedName = cleaned(name)
        if let locked = cleaned(lockedRouteTitle),
           locked.caseInsensitiveCompare(cleanedName ?? "") != .orderedSame {
            return locked
        }
        let cleanedCountry = cleaned(country)
        var seen = Set<String>()
        var components = [locality, administrativeArea].compactMap { value -> String? in
            guard let value = cleaned(value),
                  value.caseInsensitiveCompare(cleanedCountry ?? "") != .orderedSame,
                  value.caseInsensitiveCompare(cleanedName ?? "") != .orderedSame else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
        // A country by itself is neither useful disambiguation nor reliable
        // for coordinate-only MKPlacemark values (MapKit can retain stale
        // simulator geocoder metadata). Include it only behind a real place
        // hierarchy such as city or region.
        if !components.isEmpty, let country = cleanedCountry {
            let key = country.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted { components.append(country) }
        }
        if !components.isEmpty { return components.joined(separator: " · ") }
        if let fallback = cleaned(fallbackTitle),
           fallback.caseInsensitiveCompare(cleanedCountry ?? "") != .orderedSame,
           fallback.caseInsensitiveCompare(cleanedName ?? "") != .orderedSame {
            return fallback
        }
        return "Ausgewähltes Ziel"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Destination activation is transactional: a failed request may restore its
/// own snapshot only while it is still the latest user selection.
enum DestinationActivationRollbackPolicy {
    static func isCurrent(request: UUID, current: UUID) -> Bool {
        request == current
    }

    static func shouldRollback(request: UUID, current: UUID) -> Bool {
        isCurrent(request: request, current: current)
    }
}

enum RouteOptionScopePolicy {
    static func waypointID(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? nil : cleaned
    }

    static func mutatesGlobalSettings(waypointID: String?) -> Bool {
        Self.waypointID(waypointID) == nil
    }
}

enum RouteOptionSettingsBaselinePolicy {
    /// SwiftUI publishes a Toggle's new value before its onChange callback.
    /// For global route options the active lock therefore is the authoritative
    /// last-calculated settings baseline; reading DriveSettings here would
    /// snapshot the unverified new switch value and make rollback inconsistent.
    static func baseline(
        waypointID: String?,
        activeDefaults: LockedRouteOptions?,
        currentAvoidTolls: Bool,
        currentAvoidHighways: Bool
    ) -> LockedRouteOptions {
        if RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: waypointID),
           let activeDefaults {
            return activeDefaults
        }
        return .init(
            avoidTolls: currentAvoidTolls,
            avoidHighways: currentAvoidHighways
        )
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

enum NavigationRerouteSupersessionPolicy {
    /// A route edit or reached mandatory waypoint starts a fresh calculation
    /// inside the same navigation session. It supersedes an automatic reroute
    /// so the older task and watchdog cannot later publish a false failure or
    /// leave the driving screen in its recalculating state. The reroute's own
    /// calculation carries a work token and must retain ownership.
    static func shouldInvalidateAutomaticReroute(
        isRecalculating: Bool,
        navigationSession: UUID?,
        navigationWork: UUID?
    ) -> Bool {
        isRecalculating && navigationSession != nil && navigationWork == nil
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

enum OfflineRouteGuidanceEligibilityPolicy {
    /// Destination matching is sufficient for a harmless cached preview, but
    /// turn-by-turn guidance must additionally prove that geometry, mandatory
    /// waypoints and per-segment options belong to the active trip lock.
    static func mayStart(available: Bool, belongsToExactActiveTrip: Bool) -> Bool {
        available && belongsToExactActiveTrip
    }
}

enum RouteSearchPolicy {
    struct DetourAnchors {
        let entry: CLLocationCoordinate2D
        let exit: CLLocationCoordinate2D
        let baselineMetres: CLLocationDistance
    }

    static func currentProgress(projected: Double?, persisted: Double?,
                                navigationActive: Bool) -> Double {
        if let projected, projected.isFinite {
            return min(1, max(0, projected))
        }
        if navigationActive, let persisted, persisted.isFinite {
            return min(1, max(0, persisted))
        }
        return 0
    }

    /// Resolves two progress signals that both describe the currently
    /// installed route. At a cloverleaf, bridge or loop, pure geometric map
    /// matching can snap to an earlier visit of the same coordinate. The
    /// distance-derived estimate has already advanced past that visit, so a
    /// route search must never move backwards and offer completed POIs again.
    static func installedProgress(projected: Double?, distanceEstimate: Double?) -> Double? {
        let values = [projected, distanceEstimate].compactMap { value -> Double? in
            guard let value, value.isFinite else { return nil }
            return min(1, max(0, value))
        }
        return values.max()
    }

    /// Estimates progress on the currently installed route geometry. This is
    /// deliberately separate from the persistent trip-corridor progress: a
    /// reroute starts its new `legs` at the current vehicle position (0%),
    /// while the original holiday corridor may already be 80% complete.
    static func installedRouteProgress(totalDistance: CLLocationDistance,
                                       remainingDistance: CLLocationDistance,
                                       navigationActive: Bool) -> Double? {
        guard navigationActive, totalDistance.isFinite, totalDistance > 0,
              remainingDistance.isFinite, remainingDistance >= 0 else { return nil }
        return min(1, max(0, 1 - remainingDistance / totalDistance))
    }

    /// Keeps a tiny tolerance for GPS jitter around the current route point,
    /// but never sends the driver materially backwards for an added stop.
    static func isAhead(candidateIndex: Int, currentIndex: Int, routePointCount: Int) -> Bool {
        guard routePointCount > 0 else { return false }
        let tolerance = max(2, routePointCount / 50)
        return candidateIndex >= max(0, currentIndex - tolerance)
    }

    static func isAhead(candidateProgress: Double, currentProgress: Double,
                        totalRouteDistance: CLLocationDistance,
                        maximumBackwardToleranceMetres: CLLocationDistance = 250) -> Bool {
        guard candidateProgress.isFinite, currentProgress.isFinite,
              totalRouteDistance.isFinite, totalRouteDistance > 0 else { return false }
        let tolerance = min(
            0.005,
            max(0, maximumBackwardToleranceMetres) / totalRouteDistance
        )
        return candidateProgress >= max(0, currentProgress - tolerance)
    }

    /// Removes the materially completed part before issuing MapKit searches.
    /// Filtering only after the provider request wastes calls on towns behind
    /// the vehicle and can crowd useful future results out of the response.
    static func remainingRouteCoordinates(_ coordinates: [CLLocationCoordinate2D],
                                          currentProgress: Double,
                                          maximumBackwardToleranceMetres: CLLocationDistance = 250)
        -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1 else { return coordinates }
        let progress = RouteGeometryProgress.cumulativeFractions(coordinates)
        let totalDistance = zip(coordinates, coordinates.dropFirst()).reduce(0.0) {
            $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }
        let tolerance = totalDistance > 0
            ? min(0.005, max(0, maximumBackwardToleranceMetres) / totalDistance)
            : 0
        let lowerBound = max(0, min(1, currentProgress) - tolerance)
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

    /// A detour that is acceptable on a 700 km holiday drive can be absurd on
    /// a 20 km local trip. Keep a useful minimum, then scale up gradually and
    /// retain the absolute safety ceiling above.
    static func maximumDetour(remainingRouteDistance: CLLocationDistance) -> CLLocationDistance {
        guard remainingRouteDistance.isFinite, remainingRouteDistance >= 0 else { return 3_000 }
        return min(20_000, max(3_000, remainingRouteDistance * 0.05))
    }

    static func acceptsDetour(_ metres: CLLocationDistance,
                              remainingRouteDistance: CLLocationDistance) -> Bool {
        acceptsDetour(metres) && metres <= maximumDetour(
            remainingRouteDistance: remainingRouteDistance
        )
    }

    /// Results should be useful rather than merely the first POI encountered.
    /// Additional driving is expensive, while a modest amount of normal route
    /// travel before the stop is usually harmless.
    static func rankingScore(detourMetres: CLLocationDistance,
                             candidateProgress: Double,
                             currentProgress: Double,
                             remainingRouteDistance: CLLocationDistance,
                             queryRelevance: Double = 0) -> Double {
        guard detourMetres.isFinite, detourMetres >= 0,
              candidateProgress.isFinite, currentProgress.isFinite,
              remainingRouteDistance.isFinite, remainingRouteDistance >= 0,
              queryRelevance.isFinite, queryRelevance >= 0 else {
            return .greatestFiniteMagnitude
        }
        let remainingFraction = max(0.000_001, 1 - min(1, max(0, currentProgress)))
        let progressAhead = max(0, candidateProgress - currentProgress)
        let distanceAhead = progressAhead / remainingFraction * remainingRouteDistance
        // MapKit category searches often produce result names unrelated to a
        // generic query such as "Essen"; those all receive the same penalty
        // and remain ranked by detour. A named brand or exact POI match,
        // however, must beat a merely nearby weak match.
        return detourMetres * 3 + distanceAhead * 0.12 + queryRelevance * 1_500
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
                                    airDistance: (C) -> CLLocationDistance,
                                    queryRelevance: (C) -> Double = { _ in 0 }) -> [C] {
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
            cluster.min {
                let lhsRelevance = queryRelevance($0)
                let rhsRelevance = queryRelevance($1)
                let lhsScore = lhsRelevance.isFinite && lhsRelevance >= 0
                    ? lhsRelevance : .greatestFiniteMagnitude
                let rhsScore = rhsRelevance.isFinite && rhsRelevance >= 0
                    ? rhsRelevance : .greatestFiniteMagnitude
                return lhsScore == rhsScore
                    ? airDistance($0) < airDistance($1)
                    : lhsScore < rhsScore
            }
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

enum RouteStopEndpointPolicy {
    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
            (-90...90).contains(coordinate.latitude) &&
            (-180...180).contains(coordinate.longitude)
    }

    /// A POI at the final destination is not an intermediate stop. Treating it
    /// as mandatory creates a duplicate final leg and can send the driver
    /// around a block after already arriving. The tolerance absorbs ordinary
    /// MapKit coordinate drift between an address and a venue entrance.
    static func isDistinctFromDestination(
        stop: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D?,
        toleranceMetres: CLLocationDistance = 100
    ) -> Bool {
        guard isValid(stop) else { return false }
        guard let destination, isValid(destination) else { return true }
        return CLLocation(latitude: stop.latitude, longitude: stop.longitude).distance(
            from: CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        ) > max(0, toleranceMetres)
    }
}

enum NavigationDestinationCoordinatePolicy {
    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite &&
            (-90...90).contains(coordinate.latitude) &&
            (-180...180).contains(coordinate.longitude)
    }
}

enum SpeedLimitSelectionPolicy {
    /// Selects the closest sampled speed-limit point near the current route
    /// progress. Pure geometric proximity can pick a later visit of the same
    /// motorway junction, bridge or loop and display the wrong limit.
    static func index(near coordinate: CLLocationCoordinate2D,
                      points: [CLLocationCoordinate2D],
                      availableLimitCount: Int,
                      expectedProgress: Double?,
                      maximumDistance: CLLocationDistance = 200) -> Int? {
        let usableCount = min(points.count, max(0, availableLimitCount))
        guard usableCount > 0, maximumDistance >= 0 else { return nil }
        let fractions = RouteGeometryProgress.cumulativeFractions(points)
        let range = expectedProgress.map {
            max(0, min(1, $0) - 0.04)...min(1, max(0, $0) + 0.08)
        }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let candidates = points.indices.prefix(usableCount).filter { index in
            guard let range else { return true }
            return fractions.indices.contains(index) && range.contains(fractions[index])
        }
        guard let best = candidates.min(by: { lhs, rhs in
            here.distance(from: CLLocation(latitude: points[lhs].latitude,
                                           longitude: points[lhs].longitude)) <
            here.distance(from: CLLocation(latitude: points[rhs].latitude,
                                           longitude: points[rhs].longitude))
        }) else { return nil }
        let distance = here.distance(from: CLLocation(latitude: points[best].latitude,
                                                       longitude: points[best].longitude))
        return distance <= maximumDistance ? best : nil
    }
}

enum SpeedLimitPresentation: Equatable {
    case numeric(Int)
    case unrestricted
    case unavailable
}

enum SpeedLimitPresentationPolicy {
    /// Numeric evidence is safer and more specific than a contradictory
    /// `unlimited` flag. Only an explicit unrestricted result without a
    /// numeric limit may display the general German restriction-end sign.
    static func presentation(for result: SpeedLimitResult) -> SpeedLimitPresentation {
        if let value = result.maxspeed, (1...300).contains(value) {
            return .numeric(value)
        }
        return result.unlimited ? .unrestricted : .unavailable
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

enum RouteSearchPublishedQueryPolicy {
    /// Results remain selectable only while the field still represents the
    /// query that produced them. Trimming and letter case are harmless editing;
    /// any material text change requires a fresh search.
    static func matches(resultQuery: String?, editedQuery: String) -> Bool {
        guard let resultQuery else { return false }
        return resultQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(
                editedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            ) == .orderedSame
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

struct OfflineGuidanceResumeEstimate: Equatable {
    let distance: CLLocationDistance
    let travelTime: TimeInterval
}

enum OfflineGuidanceResumeEstimatePolicy {
    /// A restored trip can resume far beyond the beginning of its cached
    /// geometry. Until the first fresh GPS fix arrives, the driving screen
    /// still needs an honest remaining distance and ETA instead of briefly
    /// showing the totals for the entire original journey.
    static func estimate(stepDistances: [CLLocationDistance], currentIndex: Int,
                         routeDistance: CLLocationDistance,
                         routeTravelTime: TimeInterval) -> OfflineGuidanceResumeEstimate {
        let distances = stepDistances.map { value in
            value.isFinite ? max(0, value) : 0
        }
        let totalStepDistance = distances.reduce(0, +)
        guard totalStepDistance > 0, routeDistance.isFinite, routeDistance >= 0,
              routeTravelTime.isFinite, routeTravelTime >= 0 else {
            return .init(distance: max(0, routeDistance.isFinite ? routeDistance : 0),
                         travelTime: max(0, routeTravelTime.isFinite ? routeTravelTime : 0))
        }
        let cursor = min(max(0, currentIndex), distances.count)
        let remainingStepDistance = distances.dropFirst(cursor).reduce(0, +)
        let fraction = min(1, max(0, remainingStepDistance / totalStepDistance))
        return .init(distance: routeDistance * fraction,
                     travelTime: routeTravelTime * fraction)
    }
}

enum OfflineRouteProgressPolicy {
    static func progress(liveRouteDistance: CLLocationDistance,
                         cachedRouteDistance: CLLocationDistance,
                         remainingDistance: CLLocationDistance) -> Double? {
        guard remainingDistance.isFinite, remainingDistance >= 0 else { return nil }
        let distance = liveRouteDistance > 0 ? liveRouteDistance : cachedRouteDistance
        guard distance.isFinite, distance > 0 else { return nil }
        return min(1, max(0, 1 - remainingDistance / distance))
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
    let followingManeuverStepIndex: Int?
    let followingManeuverInstruction: String?
    let distanceFromRoute: CLLocationDistance
    let courseDifferenceDegrees: Double?
}

enum OfflineGuidanceEngine {
    static func progress(at coordinate: CLLocationCoordinate2D, currentIndex: Int,
                         steps: [OfflineGuidanceStep],
                         transitionRadius: CLLocationDistance,
                         allowsFullRecovery: Bool = false,
                         courseDegrees: Double? = nil) -> OfflineGuidanceProgress? {
        guard !steps.isEmpty else { return nil }
        let cursor = min(max(0, currentIndex), steps.count - 1)
        var metrics = steps.map {
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: $0.distance,
                hasManeuverInstruction: !$0.instruction
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let evaluationIndices = allowsFullRecovery
            ? steps.indices
            : NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: cursor, stepCount: steps.count
            )
        for index in evaluationIndices {
            metrics[index] = geometryMetric(
                from: coordinate, on: steps[index].coordinates,
                stepDistance: steps[index].distance, courseDegrees: courseDegrees,
                hasManeuverInstruction: !steps[index].instruction
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: cursor, metrics: metrics,
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
                         followingManeuverStepIndex: nil,
                         followingManeuverInstruction: nil,
                         distanceFromRoute: metrics[selected].distanceFromRoute,
                         courseDifferenceDegrees: metrics[selected].courseDifferenceDegrees)
        }
        let distanceToManeuver = metrics[selected].remainingOnStep +
            steps[(selected + 1)..<maneuver].reduce(0) { $0 + $1.distance }
        let upcoming = steps[maneuver...].map(\.instruction).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let followingIndex = NavigationInstructionSequencePolicy.firstDistinctInstructionIndex(
            in: steps.map(\.instruction), after: maneuver
        )
        let followingDistance = followingIndex.map { index in
            steps[maneuver..<index].reduce(0) { $0 + $1.distance }
        }
        return .init(currentStepIndex: selected, maneuverStepIndex: maneuver,
                     instruction: steps[maneuver].instruction,
                     distanceToManeuver: max(0, distanceToManeuver),
                     remainingDistance: routeRemaining,
                     upcomingInstructions: Array(NavigationInstructionSequencePolicy
                        .removingConsecutiveDuplicates(upcoming).prefix(5)),
                     followingManeuverDistance: followingDistance,
                     followingManeuverStepIndex: followingIndex,
                     followingManeuverInstruction: followingIndex.map { steps[$0].instruction },
                     distanceFromRoute: metrics[selected].distanceFromRoute,
                     courseDifferenceDegrees: metrics[selected].courseDifferenceDegrees)
    }

    private static func geometryMetric(from coordinate: CLLocationCoordinate2D,
                                       on coordinates: [CLLocationCoordinate2D],
                                       stepDistance: CLLocationDistance,
                                       courseDegrees: Double?,
                                       hasManeuverInstruction: Bool = false) -> NavigationStepMetric {
        guard coordinates.count > 1 else {
            return .init(distanceFromRoute: .greatestFiniteMagnitude,
                         remainingOnStep: .greatestFiniteMagnitude,
                         stepDistance: stepDistance,
                         hasUsableGeometry: false,
                         hasManeuverInstruction: hasManeuverInstruction)
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
                     stepDistance: stepDistance, courseDifferenceDegrees: difference,
                     hasManeuverInstruction: hasManeuverInstruction)
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
