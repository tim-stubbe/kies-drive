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

    var sanitized: VehicleProfile {
        .init(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Mein Fahrzeug" : name,
            baseConsumptionLPer100km: Self.valid(
                baseConsumptionLPer100km, fallback: 6.5, range: 1...40
            ),
            referenceSpeedKmh: Self.valid(referenceSpeedKmh, fallback: 100, range: 30...200),
            fuelPricePerLitre: Self.valid(fuelPricePerLitre, fallback: 1.75, range: 0...10),
            tankCapacityLitres: Self.valid(tankCapacityLitres, fallback: 50, range: 5...250),
            usableTankFraction: Self.valid(usableTankFraction, fallback: 0.85, range: 0.5...0.95),
            initialFuelFraction: Self.valid(initialFuelFraction, fallback: 1, range: 0...1)
        )
    }

    private static func valid(_ value: Double, fallback: Double,
                              range: ClosedRange<Double>) -> Double {
        value.isFinite && range.contains(value) ? value : fallback
    }
}

struct SpeedScenario: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var targetSpeedKmh: Double

    static func target(_ speed: Double) -> Self {
        let safeSpeed = speed.isFinite ? min(220, max(80, speed)) : 150
        return .init(id: "target-\(Int(safeSpeed))",
                     name: "Zieltempo \(Int(safeSpeed)) km/h",
                     targetSpeedKmh: safeSpeed)
    }
}

enum TollCost: Codable, Equatable, Sendable {
    case known(amount: Decimal, currency: String, source: String, sourceURL: String?)
    case noToll(source: String, sourceURL: String?)
    case unknown(reason: String)

    var amount: Decimal? {
        if case .known(let amount, _, _, _) = self { return amount }
        if case .noToll = self { return 0 }
        return nil
    }
}

struct TollLookupBatchItem: Sendable {
    let avoidTolls: Bool
    let routeIdentity: String
    let cost: TollCost
    let fetched: Bool
}

enum TollLookupBatchOutcome: Sendable {
    case item(TollLookupBatchItem)
    case superseded
}

enum TollLookupBatchPolicy {
    /// Both route variants form one comparison. Do not publish either result
    /// until the requested pair is complete, otherwise the UI can briefly
    /// compare fresh provider data with an unrelated previous journey.
    static func requestedVariants(mainRouteAvoidsTolls: Bool,
                                  comparisonAvailable: Bool) -> Set<Bool> {
        comparisonAvailable ? Set([false, true]) : Set([mainRouteAvoidsTolls])
    }

    static func complete(_ items: [TollLookupBatchItem], expected: Set<Bool> = [false, true]) -> Bool {
        Set(items.map(\.avoidTolls)) == expected
    }

    static func mayStartRequests(route: UUID, currentRoute: UUID,
                                 request: UUID, currentRequest: UUID) -> Bool {
        route == currentRoute && request == currentRequest
    }
}

enum TollRouteIdentityPolicy {
    /// Toll evidence is route-specific. Destination and named constraints are
    /// insufficient because a closure can send the same trip over a different
    /// tolled road. A compact, rounded geometry signature keeps cache keys
    /// stable across metre-level MapKit noise while invalidating a material
    /// reroute.
    static func identity(destination: CLLocationCoordinate2D,
                         via: [DriveCoordinate],
                         distanceMetres: CLLocationDistance,
                         routeAnchors: [CLLocationCoordinate2D]) -> String {
        let destinationPart = coordinate(destination)
        let viaPart = via.map { coordinate($0.clLocationCoordinate) }.joined(separator: ";")
        let distancePart = String(Int((max(0, distanceMetres) / 500).rounded()) * 500)
        let routePart = routeAnchors.map(coordinate).joined(separator: ";")
        return [destinationPart, viaPart, distancePart, routePart].joined(separator: "|")
    }

    private static func coordinate(_ value: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", value.latitude, value.longitude)
    }
}

enum TollVariantRoutePolicy {
    static func usesComparisonRoute(requestAvoidsTolls: Bool,
                                    mainRouteAvoidsTolls: Bool,
                                    comparisonAvailable: Bool) -> Bool {
        comparisonAvailable && requestAvoidsTolls != mainRouteAvoidsTolls
    }
}

enum TollDestinationLabelPolicy {
    static func label(lockedDestinationName: String?, mapItemName: String?,
                      enteredText: String, placemarkTitle: String?) -> String {
        for candidate in [lockedDestinationName, mapItemName, enteredText, placemarkTitle] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return "Unbekanntes Ziel"
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
    static let unknownLifetime: TimeInterval = 2 * 60
    static let maximumOriginMovement: CLLocationDistance = 10_000

    static func reusable(_ snapshot: TollLookupSnapshot?, routeIdentity: String,
                         origin: CLLocationCoordinate2D, now: Date = Date()) -> TollCost? {
        guard let snapshot, snapshot.routeIdentity == routeIdentity,
              now.timeIntervalSince(snapshot.loadedAt) >= 0,
              now.timeIntervalSince(snapshot.loadedAt) <= cacheLifetime(for: snapshot.cost) else { return nil }
        let movement = CLLocation(latitude: snapshot.origin.latitude, longitude: snapshot.origin.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
        guard movement <= maximumOriginMovement else { return nil }
        return snapshot.cost
    }

    private static func cacheLifetime(for cost: TollCost) -> TimeInterval {
        if case .unknown = cost { return unknownLifetime }
        return lifetime
    }
}

enum TollLookupRequestPolicy {
    /// The standalone server bounds SearXNG at 15 seconds. Give transport a
    /// small response margin, but never inherit URLSession's much longer
    /// default while the trip comparison waits for a complete variant pair.
    static let timeout: TimeInterval = 20
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
    /// Aerodynamic drag rises strongly with speed, while congestion and
    /// stop-and-go add idling and repeated acceleration losses at very low
    /// effective speeds. This bounded U-shaped curve is a transparent planning
    /// estimate, not a replacement for measured telemetry.
    func estimate(distanceMetres: Double, effectiveSpeedKmh: Double, profile: VehicleProfile) -> FuelEstimate {
        let profile = profile.sanitized
        let reference = max(30, profile.referenceSpeedKmh)
        let speed = max(0, effectiveSpeedKmh)
        let speedRatio = max(0.3, speed / reference)
        let aerodynamicMultiplier = 0.55 + 0.45 * speedRatio * speedRatio
        // Effective speed below 60 km/h commonly means congestion rather than
        // economical steady cruising on a long-distance route. Without this
        // term, a traffic jam would misleadingly reduce the predicted fuel use.
        let congestionRatio = max(0, 60 - speed) / 30
        let congestionPenalty = 0.55 * congestionRatio * congestionRatio
        let multiplier = min(3.2, max(0.65, aerodynamicMultiplier + congestionPenalty))
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
        let trafficFactor: Double

        var totalTime: TimeInterval { limitedTime + adjustedUnlimitedTime }
    }

    static func comparisonTargetSpeed(
        configuredSpeed: Double,
        referenceSpeed: Double = 200,
        fallbackSpeed: Double = 150
    ) -> Double {
        let configured = SpeedScenario.target(configuredSpeed).targetSpeedKmh
        let reference = SpeedScenario.target(referenceSpeed).targetSpeedKmh
        return abs(configured - reference) <= 0.1
            ? SpeedScenario.target(fallbackSpeed).targetSpeedKmh
            : reference
    }

    static func scenarios(
        configuredSpeed: Double,
        referenceSpeed: Double = 200,
        fallbackSpeed: Double = 150
    ) -> [SpeedScenario] {
        let configured = SpeedScenario.target(configuredSpeed)
        let comparison = SpeedScenario.target(comparisonTargetSpeed(
            configuredSpeed: configured.targetSpeedKmh,
            referenceSpeed: referenceSpeed,
            fallbackSpeed: fallbackSpeed
        ))
        return configured.id == comparison.id ? [configured] : [configured, comparison]
    }

    static func matchesTarget(
        scenarioSpeed: Double,
        configuredSpeed: Double,
        tolerance: Double = 0.1
    ) -> Bool {
        guard scenarioSpeed.isFinite else { return false }
        let configured = SpeedScenario.target(configuredSpeed).targetSpeedKmh
        return abs(scenarioSpeed - configured) <= max(0, tolerance)
    }

    /// Measures unrestricted motorway share by route distance. Missing speed
    /// data stays conservative instead of inflating the known unrestricted
    /// samples to 100 percent of the journey.
    static func unlimitedDistanceFraction(points: [CLLocationCoordinate2D],
                                          limits: [SpeedLimitResult],
                                          fromProgress rawProgress: Double = 0) -> Double {
        guard points.count > 1 else { return 0 }
        let segmentDistances = zip(points, points.dropFirst()).map {
            CLLocation(latitude: $0.0.latitude, longitude: $0.0.longitude)
                .distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
        }
        let completeDistance = segmentDistances.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        guard completeDistance > 0 else { return 0 }
        let startDistance = completeDistance * min(1, max(0, rawProgress))
        var totalDistance = 0.0
        var unlimitedDistance = 0.0
        var travelledDistance = 0.0
        for (index, distance) in segmentDistances.enumerated() {
            guard distance.isFinite, distance > 0 else { continue }
            let segmentEnd = travelledDistance + distance
            let includedDistance = max(0, segmentEnd - max(travelledDistance, startDistance))
            travelledDistance = segmentEnd
            guard includedDistance > 0 else { continue }
            totalDistance += includedDistance
            // Only an explicit, internally consistent unrestricted result is
            // eligible for a high-speed scenario. A numeric limit alongside
            // `unlimited` is conflicting provider data and must stay
            // conservative just like a missing sample.
            if limits.indices.contains(index),
               limits[index].unlimited,
               limits[index].maxspeed == nil {
                unlimitedDistance += includedDistance
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
        let estimatedLimitedFreeFlowTime = limitedDistance / (100 / 3.6)
        let estimatedFreeFlowTime = estimatedLimitedFreeFlowTime + theoreticalUnlimitedTime
        let trafficFactor = estimatedFreeFlowTime > 0
            ? min(2.5, max(1, eta / estimatedFreeFlowTime)) : 1
        let baselineUnlimitedTime = min(
            theoreticalUnlimitedTime * trafficFactor,
            max(0, eta - minimumLimitedTime)
        )
        let limitedTime = max(minimumLimitedTime, eta - baselineUnlimitedTime)
        let congestionDelay = max(0, baselineUnlimitedTime - theoreticalUnlimitedTime)
        let attainableTargetSpeed: Double
        if targetSpeed > baselineSpeed {
            attainableTargetSpeed = baselineSpeed +
                (targetSpeed - baselineSpeed) / (trafficFactor * trafficFactor)
        } else {
            attainableTargetSpeed = targetSpeed
        }
        let adjustedUnlimitedTime = unlimitedDistance / (attainableTargetSpeed / 3.6) +
            congestionDelay
        return .init(limitedDistance: limitedDistance,
                     unlimitedDistance: unlimitedDistance,
                     limitedTime: limitedTime,
                     adjustedUnlimitedTime: adjustedUnlimitedTime,
                     trafficFactor: trafficFactor)
    }
}

struct BreakCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let progress: Double
    /// Progress on the currently installed full route. During active guidance
    /// `progress` is rebased to the remaining journey for pause/fuel maths;
    /// this original coordinate space is retained for visibility and safe
    /// waypoint insertion.
    let installedRouteProgress: Double?
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
         installedRouteProgress: Double? = nil, timeProgress: Double? = nil,
         detourMetres: Double, detourIsEstimated: Bool = true,
         isOpen: Bool?, supportsFuel: Bool = false) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.progress = progress
        self.installedRouteProgress = installedRouteProgress
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
    static func shortlist(
        _ candidates: [BreakCandidate],
        maximum: Int = 6,
        startingDistanceProgress: Double = 0,
        startingTimeProgress: Double = 0
    ) -> [BreakCandidate] {
        guard maximum > 0 else { return [] }
        let unique = candidates.reduce(into: [String: BreakCandidate]()) { result, candidate in
            if let existing = result[candidate.id] {
                result[candidate.id] = preferred(existing, candidate)
            } else {
                result[candidate.id] = candidate
            }
        }
        let distanceStart = min(1, max(0, startingDistanceProgress))
        let timeStart = min(1, max(0, startingTimeProgress))
        let buckets = Dictionary(grouping: unique.values) { candidate in
            let rawProgress: Double
            let start: Double
            if let timeProgress = candidate.timeProgress {
                rawProgress = timeProgress
                start = timeStart
            } else {
                rawProgress = candidate.progress
                start = distanceStart
            }
            // During active guidance the candidates still retain coordinates
            // in the installed full-route space. Redistribute them across the
            // remaining journey; otherwise every place after (for example)
            // 70% falls into only the final two whole-route buckets and useful
            // later pause/fuel options are discarded before planning begins.
            let remainingProgress = (rawProgress - start) / max(0.000_001, 1 - start)
            return min(maximum - 1, max(0, Int(
                min(0.999_999, max(0, remainingProgress)) * Double(maximum)
            )))
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

enum FuelStationDistributionPolicy {
    /// Converts an installed full-route position into the remaining journey's
    /// bucket space. The hard bucket count still caps map pins and provider
    /// follow-up work, while late-trip searches retain useful geographic
    /// coverage instead of collapsing into the last few original buckets.
    static func bucket(
        progress: Double,
        currentProgress: Double,
        bucketCount: Int
    ) -> Int? {
        guard progress.isFinite, currentProgress.isFinite, bucketCount > 0 else { return nil }
        let current = min(1, max(0, currentProgress))
        let candidate = min(1, max(0, progress))
        guard candidate >= current else { return nil }
        let remaining = (candidate - current) / max(0.000_001, 1 - current)
        return min(bucketCount - 1, max(0, Int(
            min(0.999_999, remaining) * Double(bucketCount)
        )))
    }
}

enum FuelStationQueryPolicy {
    static let maximumSampleCount = 6
    static let maximumResultsPerSample = 24
    static let requestTimeout: TimeInterval = 8

    static func sampleCount(remainingDistanceMetres: CLLocationDistance) -> Int {
        guard remainingDistanceMetres.isFinite, remainingDistanceMetres > 0 else { return 2 }
        let sections = Int(ceil(remainingDistanceMetres / 200_000))
        return min(maximumSampleCount, max(2, sections))
    }
}

enum SpeedLimitQueryPolicy {
    /// Route planning must remain usable when the external road-data provider
    /// is overloaded. A missing limit is safer than an indefinitely blocked
    /// enrichment task; live guidance continues without a speed warning.
    static let requestTimeout: TimeInterval = 10
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

    /// Inverse mapping used to place amenity searches at actual driving-time
    /// windows rather than at evenly spaced kilometres. Slow mountain legs
    /// and fast motorway legs therefore do not shift a planned break by hours.
    static func distanceProgress(timeProgress: Double,
                                 segments: [(distance: Double, travelTime: TimeInterval)]) -> Double {
        let valid = segments.map {
            (distance: max(0, $0.distance), travelTime: max(0, $0.travelTime))
        }.filter { $0.distance > 0 && $0.travelTime > 0 }
        let totalDistance = valid.reduce(0) { $0 + $1.distance }
        let totalTime = valid.reduce(0) { $0 + $1.travelTime }
        guard totalDistance > 0, totalTime > 0 else {
            return min(1, max(0, timeProgress))
        }
        var remainingTime = min(1, max(0, timeProgress)) * totalTime
        var elapsedDistance = 0.0
        for segment in valid {
            if remainingTime <= segment.travelTime {
                elapsedDistance += segment.distance * (remainingTime / segment.travelTime)
                return min(1, max(0, elapsedDistance / totalDistance))
            }
            remainingTime -= segment.travelTime
            elapsedDistance += segment.distance
        }
        return 1
    }
}

enum BreakAmenitySearchPolicy {
    static func distanceProgresses(
        drivingTime: TimeInterval,
        alreadyDrivenSinceBreak: TimeInterval,
        segments: [(distance: Double, travelTime: TimeInterval)],
        maximum: Int,
        startingTimeProgress: Double = 0,
        interval: TimeInterval = 2 * 60 * 60
    ) -> [Double] {
        guard drivingTime > 0, maximum > 0, interval > 0 else { return [] }
        let start = min(1, max(0, startingTimeProgress))
        let remainingDrivingTime = drivingTime * (1 - start)
        let elapsed = min(interval, max(0, alreadyDrivenSinceBreak))
        var next = max(0, interval - elapsed)
        var values: [Double] = []
        while next < remainingDrivingTime, values.count < maximum {
            values.append(RouteTravelTimeProgress.distanceProgress(
                timeProgress: start + next / drivingTime, segments: segments
            ))
            next += interval
        }
        return values
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

    static func coordinate(at rawProgress: Double,
                           on coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        guard coordinates.count > 1 else { return coordinates[0] }
        let target = min(1, max(0, rawProgress))
        let fractions = cumulativeFractions(coordinates)
        guard let upper = fractions.indices.first(where: { fractions[$0] >= target }) else {
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

struct PlannedBreak: Identifiable, Equatable {
    let id: String
    let candidate: BreakCandidate?
    let afterDriving: TimeInterval
    let duration: TimeInterval
    let routeProgress: Double
    let explanation: String
    var installedRouteProgress: Double? = nil

    var insertionRouteProgress: Double {
        candidate?.installedRouteProgress ?? installedRouteProgress ?? routeProgress
    }
}

struct PlannedFuelStop: Identifiable, Equatable {
    let id: String
    let candidate: BreakCandidate?
    let afterDistanceMetres: Double
    let routeProgress: Double
    let explanation: String
    var installedRouteProgress: Double? = nil

    var insertionRouteProgress: Double {
        candidate?.installedRouteProgress ?? installedRouteProgress ?? routeProgress
    }
}

enum PlannedStopOpeningStatusPolicy {
    /// Provider opening flags describe the lookup moment, not the estimated
    /// arrival several hours later. A currently closed place is useful only
    /// when the arrival is far enough away that the flag is no longer a safe
    /// prediction; the UI still labels that status as needing verification.
    static let staleAfter: TimeInterval = 45 * 60

    static func mayUse(isOpen: Bool?, secondsUntilArrival: TimeInterval?) -> Bool {
        guard isOpen == false else { return true }
        guard let secondsUntilArrival, secondsUntilArrival.isFinite else { return false }
        return secondsUntilArrival >= staleAfter
    }
}

struct FuelStopPlanner {
    /// Respects the configured departure level and reserves the profile's
    /// unusable fraction. Stops are placed before the reserve, never at the
    /// theoretical last kilometre of the tank.
    func plan(distanceMetres: Double, consumptionLPer100km: Double,
              vehicle: VehicleProfile, candidates: [BreakCandidate],
              routeTravelTime: TimeInterval? = nil) -> [PlannedFuelStop] {
        guard distanceMetres.isFinite, distanceMetres > 0,
              consumptionLPer100km.isFinite, consumptionLPer100km > 0,
              vehicle.tankCapacityLitres.isFinite, vehicle.tankCapacityLitres > 0,
              vehicle.usableTankFraction.isFinite,
              vehicle.initialFuelFraction.isFinite else { return [] }
        let usableFraction = min(0.95, max(0.5, vehicle.usableTankFraction))
        let reserveFraction = 1 - usableFraction
        let departureFraction = min(1, max(0, vehicle.initialFuelFraction))
        let departureUsableLitres = vehicle.tankCapacityLitres * max(0, departureFraction - reserveFraction)
        let fullUsableLitres = vehicle.tankCapacityLitres * usableFraction
        let departureSafeRange = departureUsableLitres / consumptionLPer100km * 100_000
        let fullSafeRange = fullUsableLitres / consumptionLPer100km * 100_000
        guard fullSafeRange > 0, distanceMetres > departureSafeRange else { return [] }
        var remaining = candidates.filter { candidate in
            let arrival = routeTravelTime.flatMap { travelTime -> TimeInterval? in
                guard travelTime.isFinite, travelTime >= 0 else { return nil }
                return (candidate.timeProgress ?? candidate.progress) * travelTime
            }
            return candidate.supportsFuel && PlannedStopOpeningStatusPolicy.mayUse(
                isOpen: candidate.isOpen, secondsUntilArrival: arrival
            )
        }
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
                    "Tankstopp vor der Reserve · \($0.detourIsEstimated ? "ca. " : "")\(Int($0.detourMetres)) m Umweg" +
                        ($0.isOpen == false ? " · Öffnungsstatus bei Ankunft prüfen." : "")
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
    var deliveredReminderRawValues: Set<Int> = []
    /// A reminder can be visually delivered while its status-priority speech
    /// is rejected by an active maneuver, Siri or a call. Persist the stage so
    /// it remains retryable after a background suspension or app restart.
    var pendingSpokenReminderRawValue: Int?

    init(tripID: UUID? = nil, continuousDriving: TimeInterval = 0,
         lastSampleAt: Date? = nil, stationarySince: Date? = nil,
         deliveredReminderRawValues: Set<Int> = [],
         pendingSpokenReminderRawValue: Int? = nil) {
        self.tripID = tripID
        self.continuousDriving = continuousDriving
        self.lastSampleAt = lastSampleAt
        self.stationarySince = stationarySince
        self.deliveredReminderRawValues = deliveredReminderRawValues
        self.pendingSpokenReminderRawValue = pendingSpokenReminderRawValue
    }

    private enum CodingKeys: String, CodingKey {
        case tripID, continuousDriving, lastSampleAt, stationarySince
        case deliveredReminderRawValues, pendingSpokenReminderRawValue
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tripID = try values.decodeIfPresent(UUID.self, forKey: .tripID)
        continuousDriving = try values.decodeIfPresent(TimeInterval.self, forKey: .continuousDriving) ?? 0
        lastSampleAt = try values.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        stationarySince = try values.decodeIfPresent(Date.self, forKey: .stationarySince)
        deliveredReminderRawValues = try values.decodeIfPresent(
            Set<Int>.self, forKey: .deliveredReminderRawValues
        ) ?? []
        pendingSpokenReminderRawValue = try values.decodeIfPresent(
            Int.self, forKey: .pendingSpokenReminderRawValue
        )
    }
}

enum DrivingRestPolicy {
    // Slow stop-and-go traffic is still driving and must never reset the
    // fatigue timer. Stay above normal stationary GPS jitter, but well below
    // walking/creeping speed so only a genuinely stopped vehicle starts rest.
    static let movingThresholdMetresPerSecond = 0.8
    static let maximumCountedSampleGap: TimeInterval = 2 * 60
    static let restResetDuration: TimeInterval = 20 * 60

    static func confirmedBreak(_ previous: DrivingRestState, tripID: UUID,
                               at date: Date) -> DrivingRestState {
        DrivingRestState(
            tripID: tripID,
            continuousDriving: 0,
            lastSampleAt: date,
            stationarySince: date,
            deliveredReminderRawValues: []
        )
    }

    static func paused(_ previous: DrivingRestState, tripID: UUID,
                       at date: Date, speedMetresPerSecond: Double?) -> DrivingRestState {
        var state = previous.tripID == tripID ? previous : DrivingRestState(tripID: tripID)
        guard let speedMetresPerSecond, speedMetresPerSecond.isFinite,
              speedMetresPerSecond >= 0,
              speedMetresPerSecond < movingThresholdMetresPerSecond else { return state }
        if state.stationarySince == nil { state.stationarySince = date }
        if state.lastSampleAt.map({ date >= $0 }) ?? true { state.lastSampleAt = date }
        return state
    }

    static func updated(_ previous: DrivingRestState, tripID: UUID,
                        at date: Date, speedMetresPerSecond: Double?) -> DrivingRestState {
        var state = previous.tripID == tripID ? previous : DrivingRestState(tripID: tripID)
        guard let speedMetresPerSecond, speedMetresPerSecond.isFinite,
              speedMetresPerSecond >= 0 else { return state }

        let priorSample = state.lastSampleAt
        let interval = priorSample.map { date.timeIntervalSince($0) } ?? 0
        guard interval >= 0 else {
            // Preserve already accumulated driving time, but rebase the
            // sampling clock after an NTP/device-clock rollback. Keeping the
            // future timestamp would freeze fatigue tracking until wall time
            // catches up; treating the gap as driving or rest would invent
            // evidence we do not have.
            state.lastSampleAt = date
            state.stationarySince = speedMetresPerSecond < movingThresholdMetresPerSecond
                ? date : nil
            return state
        }
        state.lastSampleAt = date

        // A traffic light, congestion or a short stop is not restorative.
        // Count every continuously observed interval until a full break is
        // confirmed. If the stop later reaches `restResetDuration`, the value
        // is reset below; unknown gaps remain excluded by the bounded sample
        // interval so we still never invent driving time without evidence.
        if interval <= maximumCountedSampleGap {
            state.continuousDriving += interval
        }

        if speedMetresPerSecond >= movingThresholdMetresPerSecond {
            if let stationarySince = state.stationarySince,
               date.timeIntervalSince(stationarySince) >= restResetDuration {
                state.continuousDriving = 0
            }
            state.stationarySince = nil
        } else {
            if state.stationarySince == nil {
                // Missing samples are not proof of a break: the driver may
                // have travelled throughout the gap and stopped only for this
                // fix. Count rest only from the first observed stationary fix.
                state.stationarySince = date
            }
            if let stationarySince = state.stationarySince,
               date.timeIntervalSince(stationarySince) >= restResetDuration {
                state.continuousDriving = 0
            }
        }
        return state
    }
}

enum DrivingRestConfirmationPolicy {
    static let maximumLocationAge: TimeInterval = 30

    /// Manual confirmation is exposed on both the phone and CarPlay. It may
    /// reset the fatigue timer only from a recent, trustworthy stationary
    /// sample; a missing or old zero-speed fix is not evidence that the car
    /// is still parked.
    static func mayConfirm(sampleAt: Date?, reliableSpeedMetresPerSecond: Double?,
                           now: Date, maximumAge: TimeInterval = maximumLocationAge) -> Bool {
        guard let sampleAt, let speed = reliableSpeedMetresPerSecond,
              speed.isFinite, speed >= 0,
              speed < DrivingRestPolicy.movingThresholdMetresPerSecond else { return false }
        let age = now.timeIntervalSince(sampleAt)
        return age >= -5 && age <= max(0, maximumAge)
    }
}

enum NavigationBreakReminderPolicy {
    enum Stage: Int, Hashable, CaseIterable { case plan, soon, due }

    static let planningTime: TimeInterval = 90 * 60
    static let soonTime: TimeInterval = 110 * 60
    static let dueTime: TimeInterval = 120 * 60

    static func stage(continuousDriving: TimeInterval,
                      remainingTravelTime: TimeInterval,
                      delivered: Set<Stage>) -> Stage? {
        let driven = max(0, continuousDriving)
        let remaining = max(0, remainingTravelTime)
        if driven >= dueTime, !delivered.contains(.due) { return .due }
        if driven >= soonTime, driven + remaining > dueTime,
           !delivered.contains(.soon) { return .soon }
        if driven >= planningTime, driven + remaining > dueTime,
           !delivered.contains(.plan) { return .plan }
        return nil
    }

    static func nextPlannedStopName(
        breaks: [PlannedBreak], currentRouteProgress: Double,
        minimumProgressLead: Double = 0.001
    ) -> String? {
        guard currentRouteProgress.isFinite else { return nil }
        let threshold = min(1, max(0, currentRouteProgress)) + max(0, minimumProgressLead)
        return breaks
            .filter {
                $0.insertionRouteProgress.isFinite &&
                    $0.insertionRouteProgress >= threshold
            }
            .sorted { $0.insertionRouteProgress < $1.insertionRouteProgress }
            .compactMap { planned in
                let name = planned.candidate?.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name?.isEmpty == false ? name : nil
            }
            .first
    }
}

enum DrivingRestReminderStatePolicy {
    static func changedRawValues(
        current: Set<Int>, stages: Set<NavigationBreakReminderPolicy.Stage>
    ) -> Set<Int>? {
        let updated = Set(stages.map(\.rawValue))
        return updated == current ? nil : updated
    }

    /// A status-priority reminder may wait behind an important maneuver. If
    /// the fatigue clock advances meanwhile, retry the newest urgency instead
    /// of speaking stale wording such as "in 30 minutes" after the break is
    /// already due.
    static func stageToRetry(
        pending: NavigationBreakReminderPolicy.Stage?,
        newlyDue: NavigationBreakReminderPolicy.Stage?
    ) -> NavigationBreakReminderPolicy.Stage? {
        [pending, newlyDue].compactMap { $0 }.max { $0.rawValue < $1.rawValue }
    }
}

enum NavigationBreakReminderTextPolicy {
    static func text(stage: NavigationBreakReminderPolicy.Stage,
                     plannedName: String?) -> String {
        switch stage {
        case .plan:
            return plannedName.map { "In etwa 30 Minuten Pause bei \($0) einplanen." }
                ?? "In etwa 30 Minuten eine Pause einplanen."
        case .soon:
            return plannedName.map { "Bitte in etwa 10 Minuten bei \($0) Pause einlegen." }
                ?? "Bitte in etwa 10 Minuten eine Pause einlegen."
        case .due:
            return "Bitte bei der nächsten sicheren Möglichkeit Pause einlegen."
        }
    }
}

enum NavigationBreakReminderSpeechDeliveryPolicy {
    static func shouldClearPending(pendingRawValue: Int?,
                                   completed: NavigationBreakReminderPolicy.Stage?) -> Bool {
        guard let completed else { return false }
        return pendingRawValue == completed.rawValue
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

struct DrivingFuelState: Codable, Equatable {
    var tripID: UUID?
    var observedFuelFraction: Double = 1
    var distanceSinceObservationMetres: Double = 0
    var lastCoordinate: DriveCoordinate?
    var lastSampleAt: Date?
    var deliveredReminderKeys: Set<String> = []
    var pendingSpokenReminderKey: String?
    var pendingSpokenReminderText: String?

    init(tripID: UUID? = nil, observedFuelFraction: Double = 1,
         distanceSinceObservationMetres: Double = 0,
         lastCoordinate: DriveCoordinate? = nil, lastSampleAt: Date? = nil,
         deliveredReminderKeys: Set<String> = [],
         pendingSpokenReminderKey: String? = nil,
         pendingSpokenReminderText: String? = nil) {
        self.tripID = tripID
        self.observedFuelFraction = observedFuelFraction
        self.distanceSinceObservationMetres = distanceSinceObservationMetres
        self.lastCoordinate = lastCoordinate
        self.lastSampleAt = lastSampleAt
        self.deliveredReminderKeys = deliveredReminderKeys
        self.pendingSpokenReminderKey = pendingSpokenReminderKey
        self.pendingSpokenReminderText = pendingSpokenReminderText
    }

    private enum CodingKeys: String, CodingKey {
        case tripID, observedFuelFraction, distanceSinceObservationMetres
        case lastCoordinate, lastSampleAt, deliveredReminderKeys
        case pendingSpokenReminderKey, pendingSpokenReminderText
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tripID = try values.decodeIfPresent(UUID.self, forKey: .tripID)
        observedFuelFraction = try values.decodeIfPresent(
            Double.self, forKey: .observedFuelFraction
        ) ?? 1
        distanceSinceObservationMetres = try values.decodeIfPresent(
            Double.self, forKey: .distanceSinceObservationMetres
        ) ?? 0
        lastCoordinate = try values.decodeIfPresent(DriveCoordinate.self, forKey: .lastCoordinate)
        lastSampleAt = try values.decodeIfPresent(Date.self, forKey: .lastSampleAt)
        deliveredReminderKeys = try values.decodeIfPresent(
            Set<String>.self, forKey: .deliveredReminderKeys
        ) ?? []
        pendingSpokenReminderKey = try values.decodeIfPresent(
            String.self, forKey: .pendingSpokenReminderKey
        )
        pendingSpokenReminderText = try values.decodeIfPresent(
            String.self, forKey: .pendingSpokenReminderText
        )
    }

    mutating func clearPendingSpeech() {
        pendingSpokenReminderKey = nil
        pendingSpokenReminderText = nil
    }
}

enum NavigationFuelReminderPolicy {
    enum Stage: Int, CaseIterable { case plan, soon, due }

    static func stage(distanceMetres: CLLocationDistance,
                      deliveredKeys: Set<String>, stopID: String) -> Stage? {
        guard distanceMetres.isFinite, distanceMetres >= 0 else { return nil }
        let current: Stage
        if distanceMetres <= 2_000 { current = .due }
        else if distanceMetres <= 10_000 { current = .soon }
        else if distanceMetres <= 30_000 { current = .plan }
        else { return nil }
        return deliveredKeys.contains(key(stopID: stopID, stage: current)) ? nil : current
    }

    static func key(stopID: String, stage: Stage) -> String {
        "\(stopID):\(stage.rawValue)"
    }

    /// `FuelStopPlanner` numbers a newly planned remaining journey from one
    /// again. Persisting only `fuel-1` would suppress the next real stop after
    /// the plan refreshes. Concrete stations use their provider identity;
    /// theoretical stops use a coarse installed-route section that stays
    /// stable across small traffic/reroute adjustments.
    static func reminderID(for stop: PlannedFuelStop) -> String {
        if let candidate = stop.candidate { return "station:\(candidate.id)" }
        let progress = stop.insertionRouteProgress.isFinite
            ? min(1, max(0, stop.insertionRouteProgress)) : 0
        let section = min(19, max(0, Int(progress * 20)))
        return "\(stop.id):section-\(section)"
    }

    static func keysThrough(stopID: String, stage: Stage) -> Set<String> {
        Set(Stage.allCases.filter { $0.rawValue <= stage.rawValue }.map {
            key(stopID: stopID, stage: $0)
        })
    }

    static func text(stage: Stage, stationName: String?) -> String {
        let name = stationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .plan:
            return name?.isEmpty == false
                ? "Tankstopp bei \(name!) in etwa 30 Kilometern."
                : "In etwa 30 Kilometern einen Tankstopp einplanen."
        case .soon:
            return name?.isEmpty == false
                ? "In etwa 10 Kilometern bei \(name!) tanken."
                : "In etwa 10 Kilometern tanken."
        case .due:
            return name?.isEmpty == false
                ? "Jetzt den Tankstopp bei \(name!) nehmen."
                : "Bitte bei der nächsten sicheren Möglichkeit tanken."
        }
    }

    static func remainingDistance(stop: PlannedFuelStop, currentProgress: Double,
                                  installedRouteDistance: CLLocationDistance)
        -> CLLocationDistance {
        let insertion = stop.insertionRouteProgress
        guard insertion.isFinite, currentProgress.isFinite,
              installedRouteDistance.isFinite, installedRouteDistance > 0,
              insertion >= currentProgress else {
            return max(0, stop.afterDistanceMetres)
        }
        return max(0, insertion - currentProgress) * installedRouteDistance
    }
}

enum NavigationFuelReminderSpeechDeliveryPolicy {
    static func shouldClearPending(pendingKey: String?, completedKey: String?) -> Bool {
        guard let completedKey else { return false }
        return pendingKey == completedKey
    }

    static func isRelevant(pendingKey: String?, stops: [PlannedFuelStop],
                           currentProgress: Double) -> Bool {
        guard let pendingKey, currentProgress.isFinite else { return false }
        return stops.contains { stop in
            let reminderID = NavigationFuelReminderPolicy.reminderID(for: stop)
            return PlannedRouteStopVisibilityPolicy.isAhead(
                stop.insertionRouteProgress, current: currentProgress
            ) && NavigationFuelReminderPolicy.Stage.allCases.contains { stage in
                NavigationFuelReminderPolicy.key(stopID: reminderID, stage: stage) == pendingKey
            }
        }
    }


    static func pendingStage(pendingKey: String?, stopID: String)
        -> NavigationFuelReminderPolicy.Stage? {
        guard let pendingKey else { return nil }
        return NavigationFuelReminderPolicy.Stage.allCases.first {
            NavigationFuelReminderPolicy.key(stopID: stopID, stage: $0) == pendingKey
        }
    }

    /// A deferred status announcement is rebuilt from the current nearest
    /// stop and distance. This prevents a stale 30-km message, or a reminder
    /// for a later stop, from being spoken after route planning has changed.
    static func stageToRetry(pendingKey: String?, stopID: String,
                             newlyDue: NavigationFuelReminderPolicy.Stage?)
        -> NavigationFuelReminderPolicy.Stage? {
        let pending = pendingStage(pendingKey: pendingKey, stopID: stopID)
        return [pending, newlyDue].compactMap { $0 }.max { $0.rawValue < $1.rawValue }
    }
}

enum DrivingFuelPolicy {
    static let maximumCountedSampleGap: TimeInterval = 2 * 60

    static func updated(_ previous: DrivingFuelState, tripID: UUID,
                        initialFuelFraction: Double, location: CLLocation) -> DrivingFuelState {
        var state = previous.tripID == tripID
            ? previous
            : DrivingFuelState(tripID: tripID,
                               observedFuelFraction: min(1, max(0, initialFuelFraction)))
        if let prior = state.lastCoordinate, let priorDate = state.lastSampleAt {
            let interval = location.timestamp.timeIntervalSince(priorDate)
            let distance = CLLocation(latitude: prior.latitude, longitude: prior.longitude)
                .distance(from: location)
            let plausibleDistance = max(350, interval * 80)
            let reliableSpeed = NavigationMotionPolicy.reliableSpeed(for: location)
            // A stationary receiver can wander several metres on every fix.
            // Prefer Core Location's reliable speed; without one, require a
            // displacement clearly larger than this fix's uncertainty before
            // consuming fuel from the estimated tank level.
            let provesMovement = reliableSpeed.map {
                $0 >= DrivingRestPolicy.movingThresholdMetresPerSecond
            } ?? (distance > max(25, max(0, location.horizontalAccuracy) * 2))
            if interval > 0, interval <= maximumCountedSampleGap,
               distance.isFinite, distance <= plausibleDistance, provesMovement {
                state.distanceSinceObservationMetres += distance
            }
        }
        state.lastCoordinate = .init(latitude: location.coordinate.latitude,
                                     longitude: location.coordinate.longitude)
        state.lastSampleAt = location.timestamp
        return state
    }

    static func confirmed(_ previous: DrivingFuelState, tripID: UUID,
                          fraction: Double, location: CLLocation?) -> DrivingFuelState {
        DrivingFuelState(
            tripID: tripID, observedFuelFraction: min(1, max(0, fraction)),
            distanceSinceObservationMetres: 0,
            lastCoordinate: location.map {
                .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            },
            lastSampleAt: location?.timestamp
        )
    }

    static func estimatedFraction(_ state: DrivingFuelState, tripID: UUID,
                                  tankCapacityLitres: Double,
                                  consumptionLPer100km: Double,
                                  fallback: Double) -> Double {
        let safeFallback = fallback.isFinite ? min(1, max(0, fallback)) : 0
        guard state.tripID == tripID,
              state.observedFuelFraction.isFinite,
              state.distanceSinceObservationMetres.isFinite,
              tankCapacityLitres.isFinite, tankCapacityLitres > 0,
              consumptionLPer100km.isFinite, consumptionLPer100km >= 0 else {
            return safeFallback
        }
        let observedLitres = min(1, max(0, state.observedFuelFraction)) * tankCapacityLitres
        let usedLitres = max(0, state.distanceSinceObservationMetres) / 100_000 *
            max(0, consumptionLPer100km)
        let fraction = (observedLitres - usedLitres) / tankCapacityLitres
        return fraction.isFinite ? min(1, max(0, fraction)) : safeFallback
    }
}

struct DrivingFuelStateStore {
    let defaults: UserDefaults
    var key = "drive.longTrip.drivingFuelState"

    static let live = DrivingFuelStateStore(defaults: .standard)

    func load() -> DrivingFuelState {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(DrivingFuelState.self, from: data) else {
            return DrivingFuelState()
        }
        let state = persistenceSnapshot(decoded)
        // One-time privacy migration for releases that persisted the last
        // exact GPS fix. Rewrite immediately instead of waiting for another
        // drive checkpoint.
        if decoded.lastCoordinate != nil || decoded.lastSampleAt != nil,
           let sanitized = try? JSONEncoder().encode(state) {
            defaults.set(sanitized, forKey: key)
        }
        return state
    }

    func save(_ state: DrivingFuelState) {
        guard let data = try? JSONEncoder().encode(persistenceSnapshot(state)) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }

    /// The live point is needed only to measure the next short segment. It is
    /// never required to estimate remaining fuel across a restart and must
    /// not become a stored location record.
    private func persistenceSnapshot(_ state: DrivingFuelState) -> DrivingFuelState {
        var snapshot = state
        snapshot.lastCoordinate = nil
        snapshot.lastSampleAt = nil
        return snapshot
    }
}

enum RemainingRoutePlanningPolicy {
    static func projectionRange(distanceProgress: Double,
                                totalDistance: CLLocationDistance,
                                backwardToleranceMetres: CLLocationDistance = 250)
        -> ClosedRange<Double>? {
        guard distanceProgress.isFinite,
              totalDistance.isFinite, totalDistance > 0 else { return nil }
        let progress = min(1, max(0, distanceProgress))
        let tolerance = min(0.005, max(0, backwardToleranceMetres) / totalDistance)
        return max(0, progress - tolerance)...1
    }

    static func rebasedCandidates(_ candidates: [BreakCandidate],
                                  distanceProgress: Double,
                                  timeProgress: Double) -> [BreakCandidate] {
        let distanceStart = min(1, max(0, distanceProgress))
        let timeStart = min(1, max(0, timeProgress))
        let distanceRemainder = max(0.000_001, 1 - distanceStart)
        let timeRemainder = max(0.000_001, 1 - timeStart)
        return candidates.compactMap { candidate in
            let candidateTime = candidate.timeProgress ?? candidate.progress
            // Physical route progress is authoritative for whether a place is
            // still ahead. Traffic can shorten the current ETA enough that a
            // previously stored time fraction appears to be behind `timeStart`
            // even though the stop is visibly kilometres ahead on the route.
            guard candidate.progress > distanceStart + 0.000_1 else { return nil }
            let rebasedDistance = min(1, max(0,
                (candidate.progress - distanceStart) / distanceRemainder
            ))
            let rebasedTime: Double
            if candidate.timeProgress != nil,
               candidateTime > timeStart + 0.000_1 {
                rebasedTime = min(1, max(0,
                    (candidateTime - timeStart) / timeRemainder
                ))
            } else {
                // A missing or traffic-invalidated time position safely falls
                // back to monotonic remaining distance instead of deleting the
                // only usable pause/fuel candidate.
                rebasedTime = rebasedDistance
            }
            return BreakCandidate(
                id: candidate.id, name: candidate.name, coordinate: candidate.coordinate,
                progress: rebasedDistance,
                installedRouteProgress: candidate.installedRouteProgress ?? candidate.progress,
                timeProgress: rebasedTime,
                detourMetres: candidate.detourMetres,
                detourIsEstimated: candidate.detourIsEstimated,
                isOpen: candidate.isOpen, supportsFuel: candidate.supportsFuel
            )
        }
    }

    static func estimatedFuelFraction(departureFraction: Double,
                                      tankCapacityLitres: Double,
                                      consumptionLPer100km: Double,
                                      travelledDistanceMetres: Double) -> Double {
        guard tankCapacityLitres > 0 else { return 0 }
        let departureLitres = min(1, max(0, departureFraction)) * tankCapacityLitres
        let usedLitres = max(0, travelledDistanceMetres) / 100_000 * max(0, consumptionLPer100km)
        return min(1, max(0, (departureLitres - usedLitres) / tankCapacityLitres))
    }
}

struct BreakPlanner {
    var maximumContinuousDriving: TimeInterval = 2 * 60 * 60
    var defaultBreakDuration: TimeInterval = 20 * 60
    var earliestStopTolerance: TimeInterval = 20 * 60

    func plan(drivingTime: TimeInterval, candidates: [BreakCandidate],
              plannedFuelStops: [PlannedFuelStop] = [],
              alreadyDrivenSinceBreak: TimeInterval = 0) -> [PlannedBreak] {
        let elapsed = min(maximumContinuousDriving, max(0, alreadyDrivenSinceBreak))
        guard drivingTime + elapsed > maximumContinuousDriving else { return [] }
        var remaining = candidates.filter { candidate in
            let arrival = (candidate.timeProgress ?? candidate.progress) * drivingTime
            return PlannedStopOpeningStatusPolicy.mayUse(
                isOpen: candidate.isOpen, secondsUntilArrival: arrival
            )
        }
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
            // A named amenity may move the stop slightly earlier, never past
            // the configured continuous-driving limit. If no verified place
            // exists before the boundary, retain the theoretical safe stop
            // instead of presenting a late place as an optimal recommendation.
            let latestDrivingTime = min(drivingTime, idealDrivingTime)
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
            let best: BreakCandidate?
            if let coordinatedFuelStop {
                // An unverified fuel requirement is a route position, not
                // evidence that an unrelated nearby rest area sells fuel.
                // Keep the stop unverified until a concrete fuel candidate is
                // known instead of combining the name/coordinate of one place
                // with the progress and purpose of another.
                best = coordinatedFuelStop.candidate
            } else {
                best = candidatesInWindow.min {
                    score($0, idealProgress: idealProgress) < score($1, idealProgress: idealProgress)
                }
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

enum LongTripPlanRefreshPolicy {
    static let periodicInterval: TimeInterval = 5 * 60
    static let passedStopProgressLead = 0.001

    /// A named stop that is now behind the vehicle must be replaced
    /// immediately. Theoretical "pause near here" markers are excluded: when
    /// a break is already due they can intentionally sit at the current
    /// progress and would otherwise force a rebuild on every GPS fix.
    static func hasPassedConcreteStop(
        _ result: RouteScenarioResult?,
        currentInstalledProgress: Double,
        minimumLead: Double = passedStopProgressLead
    ) -> Bool {
        guard let result, currentInstalledProgress.isFinite else { return false }
        let threshold = min(1, max(0, currentInstalledProgress)) - max(0, minimumLead)
        let concreteBreaks = result.breaks.filter { $0.candidate != nil }
        let concreteFuelStops = result.fuelStops.filter { $0.candidate != nil }
        return concreteBreaks.contains { $0.insertionRouteProgress < threshold } ||
            concreteFuelStops.contains { $0.insertionRouteProgress < threshold }
    }

    static func periodicRefreshIsDue(lastRefresh: Date?, now: Date) -> Bool {
        guard let lastRefresh else { return true }
        let elapsed = now.timeIntervalSince(lastRefresh)
        return elapsed < 0 || elapsed >= periodicInterval
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
        let bothConfirmedNoToll: Bool
        switch (baseline.toll, alternative.toll) {
        case let (.known(baselineAmount, baselineCurrency, _, _),
                  .known(alternativeAmount, alternativeCurrency, _, _))
            where baselineCurrency.caseInsensitiveCompare(alternativeCurrency) == .orderedSame:
            tollSavings = baselineAmount - alternativeAmount
            tollCurrency = baselineCurrency.uppercased()
            bothConfirmedNoToll = false
        case let (.known(amount, currency, _, _), .noToll):
            tollSavings = amount
            tollCurrency = currency.uppercased()
            bothConfirmedNoToll = false
        case let (.noToll, .known(amount, currency, _, _)):
            tollSavings = -amount
            tollCurrency = currency.uppercased()
            bothConfirmedNoToll = false
        case (.noToll, .noToll):
            // There is no toll delta to display and neither provider result
            // carries a currency. Do not manufacture a €0.00 amount; only the
            // already-euro-denominated fuel difference contributes to total.
            tollSavings = nil
            tollCurrency = nil
            bothConfirmedNoToll = true
        default:
            tollSavings = nil
            tollCurrency = nil
            bothConfirmedNoToll = false
        }
        if tollCurrency == "EUR", let tollSavings {
            totalCostDifference = fuelCostDifference - NSDecimalNumber(decimal: tollSavings).doubleValue
        } else if bothConfirmedNoToll {
            totalCostDifference = fuelCostDifference
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
    /// Absolute progress where this planning slice begins on the installed
    /// route. Zero for a preview; greater than zero when planning only the
    /// remaining part of an active journey.
    var installedRouteStartProgress: Double = 0
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

struct SpeedScenarioComparison: Equatable {
    let baseline: RouteScenarioResult
    let alternative: RouteScenarioResult

    var delta: RouteComparisonDelta {
        RouteComparisonDelta(from: baseline, to: alternative)
    }

    var eligibleDistanceMetres: Double {
        baseline.distanceMetres * min(1, max(0, baseline.unlimitedFraction))
    }
}

enum SpeedScenarioComparisonPolicy {
    /// Finds two speed scenarios for the same physical route. A tolerance is
    /// intentional: settings can later come from sliders, remote commands or
    /// decoded server values and must not disappear because of floating-point
    /// representation noise.
    static func comparison(in plan: LongTripPlan,
                           configuredSpeed: Double,
                           referenceSpeed: Double = 200) -> SpeedScenarioComparison? {
        let tolerance = 0.1
        let comparisonSpeed = SpeedScenarioPolicy.comparisonTargetSpeed(
            configuredSpeed: configuredSpeed,
            referenceSpeed: referenceSpeed
        )
        guard let baseline = plan.results.first(where: {
                  SpeedScenarioPolicy.matchesTarget(
                      scenarioSpeed: $0.scenario.targetSpeedKmh,
                      configuredSpeed: configuredSpeed,
                      tolerance: tolerance
                  )
              }),
              let alternative = plan.results.first(where: {
                  $0.routeTitle == baseline.routeTitle &&
                      abs($0.scenario.targetSpeedKmh - comparisonSpeed) <= tolerance
              }),
              baseline.id != alternative.id else { return nil }
        return .init(baseline: baseline, alternative: alternative)
    }
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
        var note = "ETA basiert auf MapKit-Verkehrsdaten. Das Zieltempo verändert nur den geeigneten Anteil ohne bekanntes Limit; Pausen kommen anschließend hinzu."
        if routes.count < 2 {
            note += " Ein Mautvergleich erscheint nur, wenn eine echte zweite Route mit allen Pflichtpunkten und Routenvorgaben verfügbar ist."
        }
        return LongTripPlan(
            createdAt: now,
            results: results,
            note: note
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
        let unlimitedAverageSpeed = timing.unlimitedDistance /
            max(1, timing.adjustedUnlimitedTime) * 3.6
        let routeFuel = fuelModel.estimate(segments: [
            (timing.limitedDistance, limitedAverageSpeed),
            (timing.unlimitedDistance, unlimitedAverageSpeed)
        ], profile: vehicle)
        let fuelStops = fuelStopPlanner.plan(
            distanceMetres: route.distanceMetres,
            consumptionLPer100km: routeFuel.averageConsumptionLPer100km,
            vehicle: vehicle, candidates: route.breakCandidates,
            routeTravelTime: drivingTime
        ).map { installedFuelStop($0, routeStartProgress: route.installedRouteStartProgress) }
        // Prefer one useful stop over a rest break and a fuel stop a few
        // minutes apart. The normal pause window still applies, so a distant
        // station is never pulled forward merely to combine the two jobs.
        let breaks = breakPlanner.plan(
            drivingTime: drivingTime, candidates: route.breakCandidates,
            plannedFuelStops: fuelStops,
            alreadyDrivenSinceBreak: alreadyDrivenSinceBreak
        ).map { installedBreak($0, routeStartProgress: route.installedRouteStartProgress) }
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

    private func installedProgress(relative: Double, routeStartProgress: Double) -> Double {
        let start = min(1, max(0, routeStartProgress))
        return min(1, max(start, start + min(1, max(0, relative)) * (1 - start)))
    }

    private func installedFuelStop(_ stop: PlannedFuelStop,
                                   routeStartProgress: Double) -> PlannedFuelStop {
        guard stop.candidate == nil else { return stop }
        return .init(
            id: stop.id, candidate: nil,
            afterDistanceMetres: stop.afterDistanceMetres,
            routeProgress: stop.routeProgress,
            explanation: stop.explanation,
            installedRouteProgress: installedProgress(
                relative: stop.routeProgress, routeStartProgress: routeStartProgress
            )
        )
    }

    private func installedBreak(_ plannedBreak: PlannedBreak,
                                routeStartProgress: Double) -> PlannedBreak {
        guard plannedBreak.candidate == nil else { return plannedBreak }
        return .init(
            id: plannedBreak.id, candidate: nil,
            afterDriving: plannedBreak.afterDriving,
            duration: plannedBreak.duration,
            routeProgress: plannedBreak.routeProgress,
            explanation: plannedBreak.explanation,
            installedRouteProgress: installedProgress(
                relative: plannedBreak.routeProgress, routeStartProgress: routeStartProgress
            )
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
