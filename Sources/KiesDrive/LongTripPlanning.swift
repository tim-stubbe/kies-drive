import Foundation
import CoreLocation

struct VehicleProfile: Codable, Equatable {
    var name: String = "Mein Fahrzeug"
    var baseConsumptionLPer100km: Double = 6.5
    var referenceSpeedKmh: Double = 100
    var fuelPricePerLitre: Double = 1.75
    var tankCapacityLitres: Double = 50
    var usableTankFraction: Double = 0.85
}

struct SpeedScenario: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var targetSpeedKmh: Double

    static func target(_ speed: Double) -> Self {
        .init(id: "target-\(Int(speed))", name: "Zieltempo \(Int(speed)) km/h", targetSpeedKmh: speed)
    }
}

enum TollCost: Codable, Equatable {
    case known(amount: Decimal, currency: String, source: String)
    case noToll(source: String)
    case unknown(reason: String)

    var amount: Decimal? {
        if case .known(let amount, _, _) = self { return amount }
        if case .noToll = self { return 0 }
        return nil
    }
}

struct TollRouteDescriptor: Sendable {
    let routeID: String
    let distanceMetres: Double
    let countries: [String]
}

protocol TollProvider: Sendable {
    var name: String { get }
    func tollCost(for route: TollRouteDescriptor, vehicle: VehicleProfile) async throws -> TollCost
}

/// Safe default until a contracted/provider-backed toll endpoint is configured.
/// An absent price must remain absent; it is never estimated from distance.
struct UnknownTollProvider: TollProvider {
    let name = "Keine verifizierte Mautquelle"
    func tollCost(for route: TollRouteDescriptor, vehicle: VehicleProfile) async throws -> TollCost {
        .unknown(reason: "Für diese Route liegen keine belastbaren Providerdaten vor.")
    }
}

struct FuelEstimate: Codable, Equatable {
    let litres: Double
    let cost: Double
    let averageConsumptionLPer100km: Double
}

struct FuelModel {
    /// Aerodynamic drag rises strongly with speed. This bounded curve is a
    /// transparent planning estimate, not a replacement for measured telemetry.
    func estimate(distanceMetres: Double, effectiveSpeedKmh: Double, profile: VehicleProfile) -> FuelEstimate {
        let reference = max(30, profile.referenceSpeedKmh)
        let speedRatio = max(0.3, effectiveSpeedKmh / reference)
        let multiplier = min(3.2, max(0.65, 0.55 + 0.45 * speedRatio * speedRatio))
        let average = profile.baseConsumptionLPer100km * multiplier
        let litres = max(0, distanceMetres / 100_000 * average)
        return .init(litres: litres, cost: litres * max(0, profile.fuelPricePerLitre), averageConsumptionLPer100km: average)
    }

    /// Calculates limited/traffic and genuinely unrestricted motorway parts
    /// separately. A fast target therefore affects only the distance where it
    /// can actually be driven instead of distorting the whole-trip average.
    func estimate(segments: [(distanceMetres: Double, effectiveSpeedKmh: Double)],
                  profile: VehicleProfile) -> FuelEstimate {
        let estimates = segments.filter { $0.distanceMetres > 0 }.map {
            estimate(distanceMetres: $0.distanceMetres, effectiveSpeedKmh: $0.effectiveSpeedKmh,
                     profile: profile)
        }
        let totalDistance = segments.reduce(0) { $0 + max(0, $1.distanceMetres) }
        let litres = estimates.reduce(0) { $0 + $1.litres }
        let average = totalDistance > 0 ? litres / totalDistance * 100_000 : 0
        return .init(litres: litres, cost: litres * max(0, profile.fuelPricePerLitre),
                     averageConsumptionLPer100km: average)
    }
}

struct BreakCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let progress: Double
    let detourMetres: Double
    /// `nil` means the provider supplied no trustworthy opening status.
    /// Unknown is preferable to claiming that an unstaffed or closed stop is open.
    let isOpen: Bool?
    let supportsFuel: Bool

    init(id: String, name: String, coordinate: CLLocationCoordinate2D, progress: Double,
         detourMetres: Double, isOpen: Bool?, supportsFuel: Bool = false) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.progress = progress
        self.detourMetres = detourMetres
        self.isOpen = isOpen
        self.supportsFuel = supportsFuel
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum RouteGeometryProgress {
    /// Converts arbitrary polyline sampling density into real distance
    /// fractions. Dense junction geometry must not count as more trip progress
    /// than a long, sparsely sampled motorway section.
    static func cumulativeFractions(_ coordinates: [CLLocationCoordinate2D]) -> [Double] {
        guard coordinates.count > 1 else { return coordinates.map { _ in 0 } }
        var distances = [Double](repeating: 0, count: coordinates.count)
        for index in 1..<coordinates.count {
            distances[index] = distances[index - 1] + CLLocation(
                latitude: coordinates[index - 1].latitude,
                longitude: coordinates[index - 1].longitude
            ).distance(from: CLLocation(latitude: coordinates[index].latitude,
                                        longitude: coordinates[index].longitude))
        }
        guard let total = distances.last, total > 0 else { return distances.map { _ in 0 } }
        return distances.map { $0 / total }
    }
}

struct PlannedBreak: Identifiable, Equatable {
    let id: String
    let candidate: BreakCandidate?
    let afterDriving: TimeInterval
    let duration: TimeInterval
    let routeProgress: Double
    let explanation: String
}

struct PlannedFuelStop: Identifiable, Equatable {
    let id: String
    let candidate: BreakCandidate?
    let afterDistanceMetres: Double
    let routeProgress: Double
    let explanation: String
}

struct FuelStopPlanner {
    /// Assumes departure with a full tank and reserves the profile's unusable
    /// fraction. Stops are placed before the reserve, never at the theoretical
    /// last kilometre of the tank.
    func plan(distanceMetres: Double, consumptionLPer100km: Double,
              vehicle: VehicleProfile, candidates: [BreakCandidate]) -> [PlannedFuelStop] {
        guard distanceMetres > 0, consumptionLPer100km > 0,
              vehicle.tankCapacityLitres > 0 else { return [] }
        let usableLitres = vehicle.tankCapacityLitres * min(0.95, max(0.5, vehicle.usableTankFraction))
        let safeRange = usableLitres / consumptionLPer100km * 100_000
        guard safeRange > 0, distanceMetres > safeRange else { return [] }
        let count = Int(ceil(distanceMetres / safeRange)) - 1
        var remaining = candidates.filter { $0.isOpen != false && $0.supportsFuel }
        var lastProgress = 0.0
        return (1...count).map { index in
            let idealDistance = min(distanceMetres * 0.95, Double(index) * safeRange * 0.88)
            let idealProgress = idealDistance / distanceMetres
            let ahead = remaining.filter { $0.progress > lastProgress + 0.03 }
            let window = ahead.filter { abs($0.progress - idealProgress) <= 0.14 }
            let pool = window.isEmpty ? ahead : window
            let best = pool.min {
                abs($0.progress - idealProgress) + $0.detourMetres / 100_000 <
                abs($1.progress - idealProgress) + $1.detourMetres / 100_000
            }
            if let best { remaining.removeAll { $0.id == best.id } }
            let progress = best?.progress ?? idealProgress
            lastProgress = progress
            return .init(
                id: "fuel-\(index)", candidate: best,
                afterDistanceMetres: distanceMetres * progress, routeProgress: progress,
                explanation: best.map { "Tankstopp vor der Reserve · ca. \(Int($0.detourMetres)) m Umweg" }
                    ?? "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
            )
        }
    }
}

struct BreakPlanner {
    var maximumContinuousDriving: TimeInterval = 2 * 60 * 60
    var defaultBreakDuration: TimeInterval = 20 * 60

    func plan(drivingTime: TimeInterval, candidates: [BreakCandidate],
              preferredCandidateIDs: Set<String> = []) -> [PlannedBreak] {
        guard drivingTime > maximumContinuousDriving else { return [] }
        let count = max(1, Int(ceil(drivingTime / maximumContinuousDriving)) - 1)
        var remaining = candidates.filter { $0.isOpen != false }
        var lastProgress = 0.0
        return (1...count).map { index in
            // Stop after each maximum driving interval, not at evenly split
            // fractions (e.g. a five-hour trip should pause near 2h and 4h).
            let idealProgress = min(0.95, Double(index) * maximumContinuousDriving / drivingTime)
            let candidatesAhead = remaining.filter { $0.progress > lastProgress + 0.05 }
            let candidatesInWindow = candidatesAhead.filter { abs($0.progress - idealProgress) <= 0.12 }
            // A distant stop is not an "optimal" pause merely because it is
            // the only search result. Leave the location unverified instead.
            let best = candidatesInWindow.min {
                score($0, idealProgress: idealProgress, preferredCandidateIDs: preferredCandidateIDs) <
                score($1, idealProgress: idealProgress, preferredCandidateIDs: preferredCandidateIDs)
            }
            if let best {
                remaining.removeAll { $0.id == best.id }
                lastProgress = best.progress
            } else {
                lastProgress = idealProgress
            }
            let progress = best?.progress ?? idealProgress
            let detour = best.map { " · \(Int($0.detourMetres / 100) * 100) m Umweg" } ?? ""
            return PlannedBreak(
                id: "break-\(index)", candidate: best,
                afterDriving: drivingTime * progress, duration: defaultBreakDuration,
                routeProgress: progress,
                explanation: explanation(for: best, detour: detour)
            )
        }
    }

    private func explanation(for candidate: BreakCandidate?, detour: String) -> String {
        guard let candidate else {
            return "Pause nahe dem optimalen Streckenpunkt; Ort noch nicht verifiziert."
        }
        if candidate.isOpen == true {
            return "Geöffneter Halt nahe dem optimalen Pausenfenster\(detour)."
        }
        return "Halt nahe dem optimalen Pausenfenster\(detour) · Öffnungsstatus vor Abfahrt prüfen."
    }

    private func score(_ candidate: BreakCandidate, idealProgress: Double,
                       preferredCandidateIDs: Set<String>) -> Double {
        let combinedStopBonus = preferredCandidateIDs.contains(candidate.id) ? 25.0 : 0
        let unknownOpeningPenalty = candidate.isOpen == nil ? 3.0 : 0
        return abs(candidate.progress - idealProgress) * 100 +
            min(40, candidate.detourMetres / 1_000 * 8) + unknownOpeningPenalty - combinedStopBonus
    }
}

struct RouteComparisonDelta: Equatable {
    let timeDifference: TimeInterval
    let distanceDifferenceMetres: Double
    let fuelDifferenceLitres: Double
    let fuelCostDifference: Double
    let tollSavings: Decimal?

    init(from baseline: RouteScenarioResult, to alternative: RouteScenarioResult) {
        timeDifference = alternative.totalTime - baseline.totalTime
        distanceDifferenceMetres = alternative.distanceMetres - baseline.distanceMetres
        fuelDifferenceLitres = alternative.fuel.litres - baseline.fuel.litres
        fuelCostDifference = alternative.fuel.cost - baseline.fuel.cost
        if let baselineToll = baseline.toll.amount, let alternativeToll = alternative.toll.amount {
            tollSavings = baselineToll - alternativeToll
        } else {
            tollSavings = nil
        }
    }
}

struct RoutePlanningInput {
    let id: String
    let title: String
    let distanceMetres: Double
    let mapKitExpectedTravelTime: TimeInterval
    let unlimitedMotorwayFraction: Double
    let typicalUnlimitedSpeedKmh: Double
    let toll: TollCost
    let breakCandidates: [BreakCandidate]
}

struct RouteScenarioResult: Identifiable, Equatable {
    let id: String
    let routeTitle: String
    let scenario: SpeedScenario
    let distanceMetres: Double
    let drivingTime: TimeInterval
    let totalTime: TimeInterval
    let fuel: FuelEstimate
    let toll: TollCost
    let breaks: [PlannedBreak]
    let fuelStops: [PlannedFuelStop]
    let unlimitedFraction: Double
}

struct LongTripPlan: Equatable {
    let createdAt: Date
    let results: [RouteScenarioResult]
    let note: String
}

struct RouteComparison {
    let fuelModel: FuelModel
    let breakPlanner: BreakPlanner
    var fuelStopPlanner = FuelStopPlanner()

    func compare(routes: [RoutePlanningInput], scenarios: [SpeedScenario], vehicle: VehicleProfile, now: Date = Date()) -> LongTripPlan {
        let results = routes.flatMap { route in
            scenarios.map { scenario in
                result(route: route, scenario: scenario, vehicle: vehicle)
            }
        }
        return LongTripPlan(
            createdAt: now,
            results: results,
            note: "ETA basiert auf MapKit-Verkehrsdaten. Das Zieltempo verändert nur den geeigneten Anteil ohne bekanntes Limit; Pausen kommen anschließend hinzu."
        )
    }

    private func result(route: RoutePlanningInput, scenario: SpeedScenario, vehicle: VehicleProfile) -> RouteScenarioResult {
        let fraction = min(1, max(0, route.unlimitedMotorwayFraction))
        let baseline = max(1, route.typicalUnlimitedSpeedKmh)
        let target = min(max(80, scenario.targetSpeedKmh), 220)
        let baselineUnlimitedTime = route.mapKitExpectedTravelTime * fraction
        let limitedTime = max(0, route.mapKitExpectedTravelTime - baselineUnlimitedTime)
        let estimatedUnlimitedDistance = baselineUnlimitedTime * baseline / 3.6
        let unlimitedDistance = min(route.distanceMetres, max(0, estimatedUnlimitedDistance))
        let limitedDistance = max(0, route.distanceMetres - unlimitedDistance)
        let adjustedUnlimitedTime = unlimitedDistance / (target / 3.6)
        // Preserve MapKit's limited/urban/traffic component instead of assuming
        // the selected target speed applies to the whole route.
        let drivingTime = limitedTime + adjustedUnlimitedTime
        let limitedAverageSpeed = limitedDistance / max(1, limitedTime) * 3.6
        let fuel = fuelModel.estimate(segments: [
            (limitedDistance, limitedAverageSpeed),
            (unlimitedDistance, target)
        ], profile: vehicle)
        let fuelStops = fuelStopPlanner.plan(distanceMetres: route.distanceMetres,
                                             consumptionLPer100km: fuel.averageConsumptionLPer100km,
                                             vehicle: vehicle, candidates: route.breakCandidates)
        // Prefer one useful stop over a rest break and a fuel stop a few
        // minutes apart. The normal pause window still applies, so a distant
        // station is never pulled forward merely to combine the two jobs.
        let plannedFuelCandidateIDs = Set(fuelStops.compactMap { $0.candidate?.id })
        let breaks = breakPlanner.plan(drivingTime: drivingTime, candidates: route.breakCandidates,
                                       preferredCandidateIDs: plannedFuelCandidateIDs)
        return .init(
            id: "\(route.id)-\(scenario.id)", routeTitle: route.title, scenario: scenario,
            distanceMetres: route.distanceMetres, drivingTime: drivingTime,
            totalTime: drivingTime + breaks.reduce(0) { $0 + $1.duration }, fuel: fuel,
            toll: route.toll, breaks: breaks, fuelStops: fuelStops, unlimitedFraction: fraction
        )
    }
}

/// Boundary for a later DriveLog/OBD integration. Kies Drive does not own or
/// persist telemetry; callers may provide aggregated observations later.
protocol DriveTelemetryProviding: Sendable {
    func observedConsumptionLPer100km() async -> Double?
    func observedCruisingSpeedKmh() async -> Double?
}

struct NoTelemetryProvider: DriveTelemetryProviding {
    func observedConsumptionLPer100km() async -> Double? { nil }
    func observedCruisingSpeedKmh() async -> Double? { nil }
}
