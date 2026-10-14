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
    /// Estimated fuel level at departure. One means full; the reserved share
    /// from `usableTankFraction` remains unavailable for route planning.
    var initialFuelFraction: Double = 1
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
    struct TimingComponents: Equatable {
        let limitedDistance: Double
        let unlimitedDistance: Double
        let limitedTime: TimeInterval
        let adjustedUnlimitedTime: TimeInterval

        var totalTime: TimeInterval { limitedTime + adjustedUnlimitedTime }
    }

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


    /// Splits MapKit's traffic-aware ETA without ever assigning zero time to
    /// the limited part of a route. Sparse or inconsistent speed-limit data
    /// must not make a 200 km/h scenario imply motorway speed through towns,
    /// slip roads or congested limited sections.
    static func timing(distanceMetres: Double, mapKitExpectedTravelTime: TimeInterval,
                       unlimitedFraction: Double, typicalUnlimitedSpeedKmh: Double,
                       targetSpeedKmh: Double) -> TimingComponents {
        let distance = max(0, distanceMetres)
        let fraction = min(1, max(0, unlimitedFraction))
        let unlimitedDistance = distance * fraction
        let limitedDistance = max(0, distance - unlimitedDistance)
        let baselineSpeed = max(80, min(180, typicalUnlimitedSpeedKmh))
        let targetSpeed = max(80, min(220, targetSpeedKmh))
        let theoreticalUnlimitedTime = unlimitedDistance / (baselineSpeed / 3.6)
        // Even a nominally limited motorway section cannot be planned above
        // 130 km/h. MapKit traffic can only increase this reserved time.
        let minimumLimitedTime = limitedDistance / (130 / 3.6)
        let eta = max(0, mapKitExpectedTravelTime)
        let baselineUnlimitedTime = min(theoreticalUnlimitedTime,
                                        max(0, eta - minimumLimitedTime))
        let limitedTime = max(minimumLimitedTime, eta - baselineUnlimitedTime)
        let adjustedUnlimitedTime = unlimitedDistance / (targetSpeed / 3.6)
        return .init(limitedDistance: limitedDistance,
                     unlimitedDistance: unlimitedDistance,
                     limitedTime: limitedTime,
                     adjustedUnlimitedTime: adjustedUnlimitedTime)
    }
}

struct BreakCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let progress: Double
    /// Fraction of expected driving time elapsed at this point. This differs
    /// from geometric progress on slow mountain legs and congested sections.
    /// Older/imported candidates may omit it and safely fall back to distance.
    let timeProgress: Double?
    let detourMetres: Double
    /// False only after MapKit has measured the actual drive from the route
    /// to the stop and back. Air-line fallbacks remain visibly approximate.
    let detourIsEstimated: Bool
    /// `nil` means the provider supplied no trustworthy opening status.
    /// Unknown is preferable to claiming that an unstaffed or closed stop is open.
    let isOpen: Bool?
    let supportsFuel: Bool

    init(id: String, name: String, coordinate: CLLocationCoordinate2D, progress: Double,
         timeProgress: Double? = nil,
         detourMetres: Double, detourIsEstimated: Bool = true,
         isOpen: Bool?, supportsFuel: Bool = false) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.progress = progress
        self.timeProgress = timeProgress
        self.detourMetres = detourMetres
        self.detourIsEstimated = detourIsEstimated
        self.isOpen = isOpen
        self.supportsFuel = supportsFuel
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum BreakCandidateSelectionPolicy {
    /// Long routes can contain hundreds of nearby places. Keep one useful
    /// candidate per route section so the UI stays small and only a bounded
    /// number of real driving-detour requests is needed.
    static func shortlist(_ candidates: [BreakCandidate], maximum: Int = 6) -> [BreakCandidate] {
        guard maximum > 0 else { return [] }
        let unique = candidates.reduce(into: [String: BreakCandidate]()) { result, candidate in
            if let existing = result[candidate.id] {
                result[candidate.id] = preferred(existing, candidate)
            } else {
                result[candidate.id] = candidate
            }
        }
        let buckets = Dictionary(grouping: unique.values) {
            min(maximum - 1, max(0, Int(min(0.999_999, max(0, $0.timeProgress ?? $0.progress)) * Double(maximum))))
        }
        return buckets.keys.sorted().compactMap { bucket in
            buckets[bucket]?.min(by: isPreferred)
        }
    }

    private static func preferred(_ lhs: BreakCandidate, _ rhs: BreakCandidate) -> BreakCandidate {
        isPreferred(lhs, rhs) ? lhs : rhs
    }

    private static func isPreferred(_ lhs: BreakCandidate, _ rhs: BreakCandidate) -> Bool {
        let lhsScore = lhs.detourMetres + (lhs.supportsFuel ? 0 : 500) + (lhs.isOpen == false ? 10_000 : 0)
        let rhsScore = rhs.detourMetres + (rhs.supportsFuel ? 0 : 500) + (rhs.isOpen == false ? 10_000 : 0)
        return lhsScore == rhsScore ? lhs.id < rhs.id : lhsScore < rhsScore
    }
}

enum BreakCandidateFactory {
    /// Keep an absent provider opening status absent. Treating `nil` as open
    /// would make an unverified station look safe for a night-time pause.
    static func fuelStation(_ station: FuelStation, progress: Double,
                            timeProgress: Double? = nil,
                            detourMetres: Double,
                            detourIsEstimated: Bool = true) -> BreakCandidate {
        BreakCandidate(
            id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
            coordinate: station.coordinate, progress: progress, timeProgress: timeProgress,
            detourMetres: detourMetres, detourIsEstimated: detourIsEstimated,
            isOpen: station.open, supportsFuel: true
        )
    }
}

enum FuelStationSelectionPolicy {
    static func isPreferred(_ lhs: FuelStation, corridorDistance lhsDistance: Double,
                            over rhs: FuelStation, corridorDistance rhsDistance: Double) -> Bool {
        let lhsOpening = openingRank(lhs.open)
        let rhsOpening = openingRank(rhs.open)
        if lhsOpening != rhsOpening { return lhsOpening > rhsOpening }
        let lhsPrice = lhs.price > 0 && lhs.price.isFinite ? lhs.price : .greatestFiniteMagnitude
        let rhsPrice = rhs.price > 0 && rhs.price.isFinite ? rhs.price : .greatestFiniteMagnitude
        if lhsPrice != rhsPrice { return lhsPrice < rhsPrice }
        if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
        return lhs.id < rhs.id
    }

    private static func openingRank(_ value: Bool?) -> Int {
        switch value {
        case true: 2
        case nil: 1
        case false: 0
        }
    }
}

enum RouteTravelTimeProgress {
    /// Maps a point's whole-route distance fraction to its expected-time
    /// fraction using the individual MapKit leg ETAs. It intentionally works
    /// with plain values so the safety-critical math remains unit-testable.
    static func value(distanceProgress: Double,
                      segments: [(distance: Double, travelTime: TimeInterval)]) -> Double {
        let valid = segments.map {
            (distance: max(0, $0.distance), travelTime: max(0, $0.travelTime))
        }.filter { $0.distance > 0 }
        let totalDistance = valid.reduce(0) { $0 + $1.distance }
        let totalTime = valid.reduce(0) { $0 + $1.travelTime }
        guard totalDistance > 0, totalTime > 0 else {
            return min(1, max(0, distanceProgress))
        }
        var remainingDistance = min(1, max(0, distanceProgress)) * totalDistance
        var elapsedTime = 0.0
        for segment in valid {
            if remainingDistance <= segment.distance {
                elapsedTime += segment.travelTime * (remainingDistance / segment.distance)
                return min(1, max(0, elapsedTime / totalTime))
            }
            remainingDistance -= segment.distance
            elapsedTime += segment.travelTime
        }
        return 1
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
                                on route: [CLLocationCoordinate2D],
                                progressRange: ClosedRange<Double>? = nil)
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
            if let progressRange, !progressRange.contains(progress) { continue }
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
    /// Respects the configured departure level and reserves the profile's
    /// unusable fraction. Stops are placed before the reserve, never at the
    /// theoretical last kilometre of the tank.
    func plan(distanceMetres: Double, consumptionLPer100km: Double,
              vehicle: VehicleProfile, candidates: [BreakCandidate]) -> [PlannedFuelStop] {
        guard distanceMetres > 0, consumptionLPer100km > 0,
              vehicle.tankCapacityLitres > 0 else { return [] }
        let usableFraction = min(0.95, max(0.5, vehicle.usableTankFraction))
        let reserveFraction = 1 - usableFraction
        let departureFraction = min(1, max(0, vehicle.initialFuelFraction))
        let departureUsableLitres = vehicle.tankCapacityLitres * max(0, departureFraction - reserveFraction)
        let fullUsableLitres = vehicle.tankCapacityLitres * usableFraction
        let departureSafeRange = departureUsableLitres / consumptionLPer100km * 100_000
        let fullSafeRange = fullUsableLitres / consumptionLPer100km * 100_000
        guard fullSafeRange > 0, distanceMetres > departureSafeRange else { return [] }
        var remaining = candidates.filter { $0.isOpen != false && $0.supportsFuel }
        var lastStopDistance = 0.0
        var currentSafeRange = departureSafeRange
        var result: [PlannedFuelStop] = []
        if departureSafeRange <= 0 {
            result.append(.init(
                id: "fuel-1", candidate: nil,
                afterDistanceMetres: 0, routeProgress: 0,
                explanation: "Tankstand liegt auf der Sicherheitsreserve · vor Abfahrt tanken."
            ))
            currentSafeRange = fullSafeRange
        }
        // Each leg is checked from the actual previous stop, not from a fixed
        // whole-trip grid. This prevents a slightly late first station from
        // making the following leg silently exceed the safe tank range.
        while distanceMetres - lastStopDistance > currentSafeRange {
            let index = result.count + 1
            let idealDistance = min(distanceMetres * 0.95, lastStopDistance + currentSafeRange * 0.88)
            let latestSafeDistance = min(distanceMetres, lastStopDistance + currentSafeRange * 0.95)
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
                explanation: best.map {
                    "Tankstopp vor der Reserve · \($0.detourIsEstimated ? "ca. " : "")\(Int($0.detourMetres)) m Umweg"
                }
                    ?? "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
            ))
            guard stopDistance > lastStopDistance else { break }
            lastStopDistance = stopDistance
            currentSafeRange = fullSafeRange
        }
        return result
    }
}

struct DrivingRestState: Codable, Equatable {
    var tripID: UUID?
    var continuousDriving: TimeInterval = 0
    var lastSampleAt: Date?
    var stationarySince: Date?
}

enum DrivingRestPolicy {
    static let movingThresholdMetresPerSecond = 2.5
    static let maximumCountedSampleGap: TimeInterval = 2 * 60
    static let restResetDuration: TimeInterval = 20 * 60

    static func updated(_ previous: DrivingRestState, tripID: UUID,
                        at date: Date, speedMetresPerSecond: Double?) -> DrivingRestState {
        var state = previous.tripID == tripID ? previous : DrivingRestState(tripID: tripID)
        guard let speedMetresPerSecond, speedMetresPerSecond.isFinite,
              speedMetresPerSecond >= 0 else { return state }

        let priorSample = state.lastSampleAt
        let interval = priorSample.map { date.timeIntervalSince($0) } ?? 0
        guard interval >= 0 else { return state }
        let wasStationary = state.stationarySince != nil
        state.lastSampleAt = date

        if speedMetresPerSecond >= movingThresholdMetresPerSecond {
            if let stationarySince = state.stationarySince,
               date.timeIntervalSince(stationarySince) >= restResetDuration {
                state.continuousDriving = 0
            }
            state.stationarySince = nil
            if !wasStationary, interval <= maximumCountedSampleGap {
                state.continuousDriving += interval
            }
        } else {
            if state.stationarySince == nil {
                // A large gap followed by a stationary fix is useful evidence
                // of a real stop. A short gap may still contain the final
                // metres of driving, so the pause starts at the current fix.
                state.stationarySince = interval > maximumCountedSampleGap ? priorSample : date
            }
            if let stationarySince = state.stationarySince,
               date.timeIntervalSince(stationarySince) >= restResetDuration {
                state.continuousDriving = 0
            }
        }
        return state
    }
}

struct DrivingRestStateStore {
    let defaults: UserDefaults
    var key = "drive.longTrip.drivingRestState"

    static let live = DrivingRestStateStore(defaults: .standard)

    func load() -> DrivingRestState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(DrivingRestState.self, from: data) else {
            return DrivingRestState()
        }
        return state
    }

    func save(_ state: DrivingRestState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}

struct BreakPlanner {
    var maximumContinuousDriving: TimeInterval = 2 * 60 * 60
    var defaultBreakDuration: TimeInterval = 20 * 60
    var earliestStopTolerance: TimeInterval = 20 * 60
    var latestStopTolerance: TimeInterval = 10 * 60

    func plan(drivingTime: TimeInterval, candidates: [BreakCandidate],
              plannedFuelStops: [PlannedFuelStop] = [],
              alreadyDrivenSinceBreak: TimeInterval = 0) -> [PlannedBreak] {
        let elapsed = min(maximumContinuousDriving, max(0, alreadyDrivenSinceBreak))
        guard drivingTime + elapsed > maximumContinuousDriving else { return [] }
        var remaining = candidates.filter { $0.isOpen != false }
        var remainingFuelStops = plannedFuelStops
        // Negative means the current continuous-driving interval began before
        // this remaining route. PlannedBreak.afterDriving stays relative to
        // now, which is what the UI communicates to the driver.
        var lastBreakDrivingTime = -elapsed
        var result: [PlannedBreak] = []
        while drivingTime - lastBreakDrivingTime > maximumContinuousDriving {
            let index = result.count + 1
            let idealDrivingTime = lastBreakDrivingTime + maximumContinuousDriving
            let idealProgress = min(0.95, max(0, idealDrivingTime / drivingTime))
            let earliestDrivingTime = max(0,
                                          idealDrivingTime - earliestStopTolerance)
            let latestDrivingTime = min(drivingTime, idealDrivingTime + latestStopTolerance)
            let coordinatedFuelStop = remainingFuelStops
                .filter {
                    let stopTime = ($0.candidate?.timeProgress ?? $0.routeProgress) * drivingTime
                    return stopTime > lastBreakDrivingTime &&
                        stopTime >= earliestDrivingTime && stopTime <= latestDrivingTime
                }
                .min {
                    abs(($0.candidate?.timeProgress ?? $0.routeProgress) * drivingTime - idealDrivingTime) <
                        abs(($1.candidate?.timeProgress ?? $1.routeProgress) * drivingTime - idealDrivingTime)
                }
            let candidatesAhead = remaining.filter {
                let candidateTime = ($0.timeProgress ?? $0.progress) * drivingTime
                return candidateTime >= earliestDrivingTime &&
                    candidateTime <= latestDrivingTime
            }
            let candidatesInWindow = candidatesAhead.filter {
                abs(($0.timeProgress ?? $0.progress) - idealProgress) <= 0.12
            }
            // A distant stop is not an "optimal" pause merely because it is
            // the only search result. Leave the location unverified instead.
            // A required fuel stop inside the safe pause window always does both
            // jobs. This also coordinates theoretical fuel stops for which the
            // concrete station has not been verified yet.
            let best = coordinatedFuelStop?.candidate ?? candidatesInWindow.min {
                score($0, idealProgress: idealProgress) < score($1, idealProgress: idealProgress)
            }
            if let best {
                remaining.removeAll { $0.id == best.id }
            }
            if let coordinatedFuelStop {
                remainingFuelStops.removeAll { $0.id == coordinatedFuelStop.id }
            }
            let progress = coordinatedFuelStop?.routeProgress ?? best?.progress ?? idealProgress
            let selectedTimeProgress = coordinatedFuelStop?.candidate?.timeProgress
                ?? best?.timeProgress
                ?? coordinatedFuelStop?.routeProgress
                ?? progress
            let breakDrivingTime = drivingTime * selectedTimeProgress
            let detour = best.map {
                " · \($0.detourIsEstimated ? "ca. " : "")\(Int($0.detourMetres / 100) * 100) m Umweg"
            } ?? ""
            result.append(PlannedBreak(
                id: "break-\(index)", candidate: best,
                afterDriving: breakDrivingTime, duration: defaultBreakDuration,
                routeProgress: progress,
                explanation: explanation(for: best, detour: detour,
                                         combinesFuelStop: coordinatedFuelStop != nil)
            ))
            guard breakDrivingTime > lastBreakDrivingTime else { break }
            lastBreakDrivingTime = breakDrivingTime
        }
        return result
    }

    private func explanation(for candidate: BreakCandidate?, detour: String,
                             combinesFuelStop: Bool) -> String {
        guard let candidate else {
            if combinesFuelStop {
                return "Tank- und Pausenstopp im sicheren Zeitfenster; konkrete Station noch nicht verifiziert."
            }
            return "Pause nahe dem optimalen Streckenpunkt; Ort noch nicht verifiziert."
        }
        let purpose = combinesFuelStop ? "Tank- und Pausenstopp" : "Halt"
        if candidate.isOpen == true {
            return "Geöffneter \(purpose) nahe dem optimalen Pausenfenster\(detour)."
        }
        return "\(purpose) nahe dem optimalen Pausenfenster\(detour) · Öffnungsstatus vor Abfahrt prüfen."
    }

    private func score(_ candidate: BreakCandidate, idealProgress: Double) -> Double {
        let unknownOpeningPenalty = candidate.isOpen == nil ? 3.0 : 0
        return abs((candidate.timeProgress ?? candidate.progress) - idealProgress) * 100 +
            min(40, candidate.detourMetres / 1_000 * 8) + unknownOpeningPenalty
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

    func compare(routes: [RoutePlanningInput], scenarios: [SpeedScenario], vehicle: VehicleProfile,
                 alreadyDrivenSinceBreak: TimeInterval = 0, now: Date = Date()) -> LongTripPlan {
        let results = routes.flatMap { route in
            scenarios.map { scenario in
                result(route: route, scenario: scenario, vehicle: vehicle,
                       alreadyDrivenSinceBreak: alreadyDrivenSinceBreak)
            }
        }
        return LongTripPlan(
            createdAt: now,
            results: results,
            note: "ETA basiert auf MapKit-Verkehrsdaten. Das Zieltempo verändert nur den geeigneten Anteil ohne bekanntes Limit; Pausen kommen anschließend hinzu."
        )
    }

    private func result(route: RoutePlanningInput, scenario: SpeedScenario, vehicle: VehicleProfile,
                        alreadyDrivenSinceBreak: TimeInterval) -> RouteScenarioResult {
        let fraction = min(1, max(0, route.unlimitedMotorwayFraction))
        let target = min(max(80, scenario.targetSpeedKmh), 220)
        let timing = SpeedScenarioPolicy.timing(
            distanceMetres: route.distanceMetres,
            mapKitExpectedTravelTime: route.mapKitExpectedTravelTime,
            unlimitedFraction: fraction,
            typicalUnlimitedSpeedKmh: route.typicalUnlimitedSpeedKmh,
            targetSpeedKmh: target
        )
        // Preserve MapKit's limited/urban/traffic component instead of assuming
        // the selected target speed applies to the whole route.
        let drivingTime = timing.totalTime
        let limitedAverageSpeed = timing.limitedDistance / max(1, timing.limitedTime) * 3.6
        let routeFuel = fuelModel.estimate(segments: [
            (timing.limitedDistance, limitedAverageSpeed),
            (timing.unlimitedDistance, target)
        ], profile: vehicle)
        let fuelStops = fuelStopPlanner.plan(distanceMetres: route.distanceMetres,
                                             consumptionLPer100km: routeFuel.averageConsumptionLPer100km,
                                             vehicle: vehicle, candidates: route.breakCandidates)
        // Prefer one useful stop over a rest break and a fuel stop a few
        // minutes apart. The normal pause window still applies, so a distant
        // station is never pulled forward merely to combine the two jobs.
        let breaks = breakPlanner.plan(drivingTime: drivingTime, candidates: route.breakCandidates,
                                       plannedFuelStops: fuelStops,
                                       alreadyDrivenSinceBreak: alreadyDrivenSinceBreak)
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
