import Foundation
import CoreLocation
import MapKit

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

struct TollLookupSnapshot: Equatable {
    let routeIdentity: String
    let origin: CLLocationCoordinate2D
    let cost: TollCost
    let loadedAt: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.routeIdentity == rhs.routeIdentity &&
        lhs.origin.latitude == rhs.origin.latitude && lhs.origin.longitude == rhs.origin.longitude &&
        lhs.cost == rhs.cost && lhs.loadedAt == rhs.loadedAt
    }
}

enum TollLookupCachePolicy {
    static let lifetime: TimeInterval = 15 * 60
    static let maximumOriginMovement: CLLocationDistance = 10_000

    static func reusable(_ snapshot: TollLookupSnapshot?, routeIdentity: String,
                         origin: CLLocationCoordinate2D, now: Date = Date()) -> TollCost? {
        guard let snapshot, snapshot.routeIdentity == routeIdentity,
              now.timeIntervalSince(snapshot.loadedAt) >= 0,
              now.timeIntervalSince(snapshot.loadedAt) <= lifetime else { return nil }
        let movement = CLLocation(latitude: snapshot.origin.latitude, longitude: snapshot.origin.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        guard movement <= maximumOriginMovement else { return nil }
        return snapshot.cost
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

enum SpeedScenarioPolicy {
    /// Measures unrestricted motorway share by route distance. Missing speed
    /// data stays conservative instead of inflating the known unrestricted
    /// samples to 100 percent of the journey.
    static func unlimitedDistanceFraction(points: [CLLocationCoordinate2D],
                                          limits: [SpeedLimitResult]) -> Double {
        guard points.count > 1 else { return 0 }
        var totalDistance = 0.0
        var unlimitedDistance = 0.0
        for index in 0..<(points.count - 1) {
            let distance = CLLocation(latitude: points[index].latitude, longitude: points[index].longitude)
                .distance(from: CLLocation(latitude: points[index + 1].latitude,
                                           longitude: points[index + 1].longitude))
            guard distance.isFinite, distance > 0 else { continue }
            totalDistance += distance
            if limits.indices.contains(index), limits[index].unlimited {
                unlimitedDistance += distance
            }
        }
        return totalDistance > 0 ? min(1, max(0, unlimitedDistance / totalDistance)) : 0
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

enum BreakCandidateFactory {
    /// Keep an absent provider opening status absent. Treating `nil` as open
    /// would make an unverified station look safe for a night-time pause.
    static func fuelStation(_ station: FuelStation, progress: Double,
                            detourMetres: Double) -> BreakCandidate {
        BreakCandidate(
            id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
            coordinate: station.coordinate, progress: progress,
            detourMetres: detourMetres, isOpen: station.open, supportsFuel: true
        )
    }
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

    static func nearestProgress(of coordinate: CLLocationCoordinate2D,
                                on route: [CLLocationCoordinate2D])
        -> (progress: Double, distance: Double, coordinate: CLLocationCoordinate2D)? {
        guard route.count > 1 else { return nil }
        let fractions = cumulativeFractions(route)
        let target = MKMapPoint(coordinate)
        let points = route.map(MKMapPoint.init)
        var best: (progress: Double, distance: Double, coordinate: CLLocationCoordinate2D)?
        for index in points.indices.dropLast() {
            let start = points[index], end = points[index + 1]
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
                ((target.x - start.x) * dx + (target.y - start.y) * dy) / lengthSquared
            ))
            let projected = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
            let distance = target.distance(to: projected)
            let progress = fractions[index] + (fractions[index + 1] - fractions[index]) * fraction
            if best == nil || distance < best!.distance {
                best = (progress, distance, projected.coordinate)
            }
        }
        return best
    }

    /// Returns points distributed by travelled distance, not by polyline point
    /// count. MapKit creates dense geometry around junctions and sparse points
    /// on long motorways; index-based sampling would otherwise waste multiple
    /// searches around one interchange and leave large route sections unseen.
    static func evenlySpaced(_ coordinates: [CLLocationCoordinate2D], maximum: Int)
        -> [CLLocationCoordinate2D] {
        guard coordinates.count > maximum, maximum > 1 else { return coordinates }
        let fractions = cumulativeFractions(coordinates)
        return (0..<maximum).map { sampleIndex in
            let target = Double(sampleIndex) / Double(maximum - 1)
            guard let upper = fractions.indices.first(where: { fractions[$0] >= target }) else {
                return coordinates[coordinates.count - 1]
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
        var remaining = candidates.filter { $0.isOpen != false && $0.supportsFuel }
        var lastStopDistance = 0.0
        var result: [PlannedFuelStop] = []
        // Each leg is checked from the actual previous stop, not from a fixed
        // whole-trip grid. This prevents a slightly late first station from
        // making the following leg silently exceed the safe tank range.
        while distanceMetres - lastStopDistance > safeRange {
            let index = result.count + 1
            let idealDistance = min(distanceMetres * 0.95, lastStopDistance + safeRange * 0.88)
            let latestSafeDistance = min(distanceMetres, lastStopDistance + safeRange * 0.95)
            let idealProgress = idealDistance / distanceMetres
            let ahead = remaining.filter {
                let candidateDistance = $0.progress * distanceMetres
                return candidateDistance > lastStopDistance + distanceMetres * 0.03 &&
                    candidateDistance <= latestSafeDistance
            }
            let window = ahead.filter { abs($0.progress - idealProgress) <= 0.14 }
            let pool = window.isEmpty ? ahead : window
            let best = pool.min {
                abs($0.progress - idealProgress) + $0.detourMetres / 100_000 <
                abs($1.progress - idealProgress) + $1.detourMetres / 100_000
            }
            if let best { remaining.removeAll { $0.id == best.id } }
            let progress = best?.progress ?? idealProgress
            let stopDistance = distanceMetres * progress
            result.append(.init(
                id: "fuel-\(index)", candidate: best,
                afterDistanceMetres: stopDistance, routeProgress: progress,
                explanation: best.map { "Tankstopp vor der Reserve · ca. \(Int($0.detourMetres)) m Umweg" }
                    ?? "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
            ))
            guard stopDistance > lastStopDistance else { break }
            lastStopDistance = stopDistance
        }
        return result
    }
}

struct BreakPlanner {
    var maximumContinuousDriving: TimeInterval = 2 * 60 * 60
    var defaultBreakDuration: TimeInterval = 20 * 60
    var earliestStopTolerance: TimeInterval = 20 * 60
    var latestStopTolerance: TimeInterval = 10 * 60

    func plan(drivingTime: TimeInterval, candidates: [BreakCandidate],
              preferredCandidateIDs: Set<String> = []) -> [PlannedBreak] {
        guard drivingTime > maximumContinuousDriving else { return [] }
        var remaining = candidates.filter { $0.isOpen != false }
        var lastBreakDrivingTime = 0.0
        var result: [PlannedBreak] = []
        while drivingTime - lastBreakDrivingTime > maximumContinuousDriving {
            let index = result.count + 1
            let idealDrivingTime = lastBreakDrivingTime + maximumContinuousDriving
            let idealProgress = min(0.95, idealDrivingTime / drivingTime)
            let earliestDrivingTime = max(lastBreakDrivingTime,
                                          idealDrivingTime - earliestStopTolerance)
            let latestDrivingTime = min(drivingTime, idealDrivingTime + latestStopTolerance)
            let candidatesAhead = remaining.filter {
                let candidateTime = $0.progress * drivingTime
                return candidateTime >= earliestDrivingTime &&
                    candidateTime <= latestDrivingTime
            }
            let candidatesInWindow = candidatesAhead.filter { abs($0.progress - idealProgress) <= 0.12 }
            // A distant stop is not an "optimal" pause merely because it is
            // the only search result. Leave the location unverified instead.
            let best = candidatesInWindow.min {
                score($0, idealProgress: idealProgress, preferredCandidateIDs: preferredCandidateIDs) <
                score($1, idealProgress: idealProgress, preferredCandidateIDs: preferredCandidateIDs)
            }
            if let best {
                remaining.removeAll { $0.id == best.id }
            }
            let progress = best?.progress ?? idealProgress
            let breakDrivingTime = drivingTime * progress
            let detour = best.map { " · \(Int($0.detourMetres / 100) * 100) m Umweg" } ?? ""
            result.append(PlannedBreak(
                id: "break-\(index)", candidate: best,
                afterDriving: breakDrivingTime, duration: defaultBreakDuration,
                routeProgress: progress,
                explanation: explanation(for: best, detour: detour)
            ))
            guard breakDrivingTime > lastBreakDrivingTime else { break }
            lastBreakDrivingTime = breakDrivingTime
        }
        return result
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
    let tollCurrency: String?
    /// Alternative minus baseline. Negative means the alternative is cheaper.
    let totalCostDifference: Double?

    init(from baseline: RouteScenarioResult, to alternative: RouteScenarioResult) {
        timeDifference = alternative.totalTime - baseline.totalTime
        distanceDifferenceMetres = alternative.totalDistanceMetres - baseline.totalDistanceMetres
        fuelDifferenceLitres = alternative.fuel.litres - baseline.fuel.litres
        fuelCostDifference = alternative.fuel.cost - baseline.fuel.cost
        switch (baseline.toll, alternative.toll) {
        case let (.known(baselineAmount, baselineCurrency, _),
                  .known(alternativeAmount, alternativeCurrency, _))
            where baselineCurrency.caseInsensitiveCompare(alternativeCurrency) == .orderedSame:
            tollSavings = baselineAmount - alternativeAmount
            tollCurrency = baselineCurrency.uppercased()
        case let (.known(amount, currency, _), .noToll):
            tollSavings = amount
            tollCurrency = currency.uppercased()
        case let (.noToll, .known(amount, currency, _)):
            tollSavings = -amount
            tollCurrency = currency.uppercased()
        case (.noToll, .noToll):
            tollSavings = 0
            tollCurrency = "EUR"
        default:
            tollSavings = nil
            tollCurrency = nil
        }
        if tollCurrency == "EUR", let tollSavings {
            totalCostDifference = fuelCostDifference - NSDecimalNumber(decimal: tollSavings).doubleValue
        } else {
            totalCostDifference = nil
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
    /// Round-trip distance from the main route to the selected real stops.
    /// A combined fuel/rest stop is counted only once.
    var plannedStopDetourMetres: Double = 0
    /// Time spent refuelling outside an already planned rest break.
    var additionalFuelStopTime: TimeInterval = 0

    var totalDistanceMetres: Double { distanceMetres + plannedStopDetourMetres }
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
        let unlimitedDistance = route.distanceMetres * fraction
        let baselineUnlimitedTime = unlimitedDistance / (baseline / 3.6)
        let limitedTime = max(0, route.mapKitExpectedTravelTime - baselineUnlimitedTime)
        let limitedDistance = max(0, route.distanceMetres - unlimitedDistance)
        let adjustedUnlimitedTime = unlimitedDistance / (target / 3.6)
        // Preserve MapKit's limited/urban/traffic component instead of assuming
        // the selected target speed applies to the whole route.
        let drivingTime = limitedTime + adjustedUnlimitedTime
        let limitedAverageSpeed = limitedDistance / max(1, limitedTime) * 3.6
        let routeFuel = fuelModel.estimate(segments: [
            (limitedDistance, limitedAverageSpeed),
            (unlimitedDistance, target)
        ], profile: vehicle)
        let fuelStops = fuelStopPlanner.plan(distanceMetres: route.distanceMetres,
                                             consumptionLPer100km: routeFuel.averageConsumptionLPer100km,
                                             vehicle: vehicle, candidates: route.breakCandidates)
        // Prefer one useful stop over a rest break and a fuel stop a few
        // minutes apart. The normal pause window still applies, so a distant
        // station is never pulled forward merely to combine the two jobs.
        let plannedFuelCandidateIDs = Set(fuelStops.compactMap { $0.candidate?.id })
        let breaks = breakPlanner.plan(drivingTime: drivingTime, candidates: route.breakCandidates,
                                       preferredCandidateIDs: plannedFuelCandidateIDs)
        let selectedCandidates = (breaks.compactMap(\.candidate) + fuelStops.compactMap(\.candidate))
            .reduce(into: [String: BreakCandidate]()) { candidates, candidate in
                candidates[candidate.id] = candidate
            }
        let detourDistance = selectedCandidates.values.reduce(0) { $0 + max(0, $1.detourMetres) }
        // Service areas and petrol stations are normally reached on slower
        // access roads. Counting their detour at motorway target speed would
        // make the time and fuel comparison unrealistically optimistic.
        let detourSpeedKmh = 50.0
        let detourDrivingTime = detourDistance / (detourSpeedKmh / 3.6)
        let detourFuel = fuelModel.estimate(distanceMetres: detourDistance,
                                            effectiveSpeedKmh: detourSpeedKmh,
                                            profile: vehicle)
        let totalDistance = route.distanceMetres + detourDistance
        let totalLitres = routeFuel.litres + detourFuel.litres
        let fuel = FuelEstimate(
            litres: totalLitres,
            cost: routeFuel.cost + detourFuel.cost,
            averageConsumptionLPer100km: totalDistance > 0 ? totalLitres / totalDistance * 100_000 : 0
        )
        let breaksCoveringFuel = Set(breaks.compactMap { $0.candidate?.id })
        let uncoveredFuelStops = fuelStops.filter { stop in
            if let id = stop.candidate?.id { return !breaksCoveringFuel.contains(id) }
            return !breaks.contains { abs($0.routeProgress - stop.routeProgress) <= 0.03 }
        }.count
        let additionalFuelStopTime = TimeInterval(uncoveredFuelStops * 10 * 60)
        let adjustedDrivingTime = drivingTime + detourDrivingTime
        return .init(
            id: "\(route.id)-\(scenario.id)", routeTitle: route.title, scenario: scenario,
            distanceMetres: route.distanceMetres, drivingTime: adjustedDrivingTime,
            totalTime: adjustedDrivingTime + breaks.reduce(0) { $0 + $1.duration } + additionalFuelStopTime,
            fuel: fuel, toll: route.toll, breaks: breaks, fuelStops: fuelStops,
            unlimitedFraction: fraction, plannedStopDetourMetres: detourDistance,
            additionalFuelStopTime: additionalFuelStopTime
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
