import Foundation
import CoreLocation
import KiesDriveCore

@MainActor
final class DriveSettings: ObservableObject {
    static let shared = DriveSettings()
    nonisolated static let standaloneBaseURL = "http://100.72.226.91:18080"
    nonisolated static let serverURLInfoKey = "KiesDriveServerURL"
    private static let legacyBaseURLs: Set<String> = [
        "https://100.72.226.91:8000",
        "http://100.72.226.91:8000",
        "https://192.168.178.65:8000",
        "http://192.168.178.65:8000",
    ]
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "drive.baseURL") } }
    @Published var fuel: FuelKind { didSet { UserDefaults.standard.set(fuel.rawValue, forKey: "drive.fuel") } }
    @Published var avoidTolls: Bool { didSet { UserDefaults.standard.set(avoidTolls, forKey: "drive.avoidTolls") } }
    @Published var avoidHighways: Bool { didSet { UserDefaults.standard.set(avoidHighways, forKey: "drive.avoidHighways") } }
    @Published var mapAppearance: DriveMapAppearance { didSet { UserDefaults.standard.set(mapAppearance.rawValue, forKey: "drive.mapAppearance") } }
    @Published var voiceGuidance: Bool { didSet { UserDefaults.standard.set(voiceGuidance, forKey: "drive.voiceGuidance") } }
    @Published var homeAddress: String { didSet { UserDefaults.standard.set(homeAddress, forKey: "drive.homeAddress") } }

    /// Fahrzeugdaten für Reichweiten-/Tankvorschläge.
    /// Einheit: L/100km und Liter.
    @Published var consumptionLPer100km: Double { didSet { UserDefaults.standard.set(consumptionLPer100km, forKey: "drive.consumptionLPer100km") } }
    @Published var tankCapacityL: Double { didSet { UserDefaults.standard.set(tankCapacityL, forKey: "drive.tankCapacityL") } }
    @Published var departureFuelPercent: Double { didSet { UserDefaults.standard.set(departureFuelPercent, forKey: "drive.departureFuelPercent") } }
    @Published var fuelPricePerLitre: Double { didSet { UserDefaults.standard.set(fuelPricePerLitre, forKey: "drive.fuelPricePerLitre") } }
    @Published var targetSpeedKmh: Double { didSet { UserDefaults.standard.set(targetSpeedKmh, forKey: "drive.targetSpeedKmh") } }

    private init() {
        let configuredBaseURL = Self.configuredBaseURL()
        let savedBaseURL = UserDefaults.standard.string(forKey: "drive.baseURL")
        if let savedBaseURL,
           savedBaseURL != Self.standaloneBaseURL,
           !Self.legacyBaseURLs.contains(savedBaseURL) {
            baseURL = savedBaseURL
        } else {
            // Release builds can provide the public HTTPS address through the
            // Info.plist. Existing development installations using the old
            // built-in address automatically follow that managed setting.
            baseURL = configuredBaseURL
            UserDefaults.standard.set(configuredBaseURL, forKey: "drive.baseURL")
        }
        fuel = FuelKind(rawValue: UserDefaults.standard.string(forKey: "drive.fuel") ?? "diesel") ?? .diesel
        avoidTolls = UserDefaults.standard.object(forKey: "drive.avoidTolls") as? Bool ?? true
        avoidHighways = UserDefaults.standard.object(forKey: "drive.avoidHighways") as? Bool ?? false
        // Pure satellite was visually noisy and is intentionally migrated to
        // the calm road map. Hybrid remains available on demand.
        mapAppearance = DriveMapAppearance(rawValue: UserDefaults.standard.string(forKey: "drive.mapAppearance") ?? "standard") ?? .standard
        voiceGuidance = UserDefaults.standard.object(forKey: "drive.voiceGuidance") as? Bool ?? true
        homeAddress = UserDefaults.standard.string(forKey: "drive.homeAddress") ?? ""

        consumptionLPer100km = UserDefaults.standard.object(forKey: "drive.consumptionLPer100km") as? Double ?? 6.5
        tankCapacityL = UserDefaults.standard.object(forKey: "drive.tankCapacityL") as? Double ?? 50.0
        departureFuelPercent = UserDefaults.standard.object(forKey: "drive.departureFuelPercent") as? Double ?? 100
        fuelPricePerLitre = UserDefaults.standard.object(forKey: "drive.fuelPricePerLitre") as? Double ?? 1.75
        targetSpeedKmh = UserDefaults.standard.object(forKey: "drive.targetSpeedKmh") as? Double ?? 150
    }

    nonisolated static func configuredBaseURL(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String {
        guard let value = info[serverURLInfoKey] as? String else { return standaloneBaseURL }
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains("$("),
              ServerEndpointPolicy.url(baseURL: candidate, path: "/healthz") != nil else {
            return standaloneBaseURL
        }
        return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    var isReady: Bool { !baseURL.isEmpty && AccountSessionStore.shared.session != nil }
    /// App-Version + Build, z.B. "1.0 (3)" - zur Diagnose, ob ein Gerät noch
    /// eine veraltete Build-Version ausführt.
    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

enum DriveAPIError: LocalizedError {
    case configuration, insecureConfiguration, twoFactorRequired, response(Int), server(String), invalidData
    var errorDescription: String? {
        switch self {
        case .configuration: "Bitte melde dich bei Kies Drive an."
        case .insecureConfiguration: "Der Kies-Drive-Server muss öffentlich HTTPS verwenden. HTTP ist nur im lokalen Netz oder über Tailscale erlaubt."
        case .twoFactorRequired: "Gib jetzt den Code aus deiner Authenticator-App ein."
        case .response(let code): "Serverfehler (HTTP \(code))."
        case .server(let message): message
        case .invalidData: "Die Serverantwort konnte nicht gelesen werden."
        }
    }
}

@MainActor
enum DriveAPI {
    private static func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let settings = DriveSettings.shared
        guard let session = AccountSessionStore.shared.session, !session.isEmpty else {
            throw DriveAPIError.configuration
        }
        guard let url = ServerEndpointPolicy.url(baseURL: settings.baseURL, path: path) else {
            throw DriveAPIError.insecureConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await KiesHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveAPIError.invalidData }
        if http.statusCode == 401 { AccountSessionStore.shared.signOut() }
        guard 200..<300 ~= http.statusCode else { throw DriveAPIError.response(http.statusCode) }
        return data
    }

    private static func authRequest(path: String, method: String = "POST", body: Data? = nil,
                                    authenticated: Bool = false) throws -> URLRequest {
        guard let url = ServerEndpointPolicy.url(baseURL: DriveSettings.shared.baseURL, path: path) else {
            throw DriveAPIError.insecureConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let session = AccountSessionStore.shared.session else { throw DriveAPIError.configuration }
            request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func authData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await KiesHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DriveAPIError.invalidData }
        guard 200..<300 ~= http.statusCode else {
            if request.value(forHTTPHeaderField: "Authorization") != nil && http.statusCode == 401 {
                AccountSessionStore.shared.signOut()
            }
            if http.statusCode == 428 { throw DriveAPIError.twoFactorRequired }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw DriveAPIError.server(detail ?? "Anmeldung fehlgeschlagen (HTTP \(http.statusCode)).")
        }
        return data
    }

    static func register(email: String, password: String) async throws -> String? {
        let body = try JSONEncoder().encode(AccountCredentials(email: email, password: password))
        let data = try await authData(for: authRequest(path: "/auth/register", body: body))
        let ticket = try JSONDecoder().decode(AccountRegistrationResponse.self, from: data).verificationTicket
        if let ticket {
            AccountSessionStore.shared.beginRegistration(ticket: ticket, email: email)
        }
        return ticket
    }

    static func completeRegistration(ticket: String) async throws -> AccountLoginResponse {
        let body = try JSONEncoder().encode(AccountRegistrationCompletion(ticket: ticket))
        let data = try await authData(for: authRequest(path: "/auth/verification/complete", body: body))
        let response = try JSONDecoder().decode(AccountLoginResponse.self, from: data)
        AccountSessionStore.shared.signIn(session: response.session, email: response.email,
                                          offerTwoFactorSetup: true)
        return response
    }

    static func requestPasswordReset(email: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        _ = try await authData(for: authRequest(path: "/auth/password/request", body: body))
    }

    static func resendVerification(email: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email])
        _ = try await authData(for: authRequest(path: "/auth/verification/resend", body: body))
    }

    static func login(email: String, password: String, totpCode: String?) async throws -> AccountLoginResponse {
        let body = try JSONEncoder().encode(AccountLoginRequest(email: email, password: password,
                                                                 totpCode: totpCode?.nilIfEmpty))
        let data = try await authData(for: authRequest(path: "/auth/login", body: body))
        let response = try JSONDecoder().decode(AccountLoginResponse.self, from: data)
        AccountSessionStore.shared.signIn(session: response.session, email: response.email)
        return response
    }

    static func account() async throws -> AccountProfile {
        let data = try await authData(for: authRequest(path: "/auth/me", method: "GET", authenticated: true))
        return try JSONDecoder().decode(AccountProfile.self, from: data)
    }

    static func setupTwoFactor() async throws -> TwoFactorSetup {
        let data = try await authData(for: authRequest(path: "/auth/2fa/setup", authenticated: true))
        return try JSONDecoder().decode(TwoFactorSetup.self, from: data)
    }

    static func enableTwoFactor(code: String) async throws -> [String] {
        let body = try JSONEncoder().encode(TwoFactorCode(code: code))
        let data = try await authData(for: authRequest(path: "/auth/2fa/enable", body: body, authenticated: true))
        return try JSONDecoder().decode(TwoFactorEnableResponse.self, from: data).recoveryCodes
    }

    static func logout() async {
        if let request = try? authRequest(path: "/auth/logout", authenticated: true) {
            _ = try? await authData(for: request)
        }
        AccountSessionStore.shared.signOut()
    }

    static func deleteAccount() async throws {
        _ = try await authData(for: authRequest(path: "/auth/account", method: "DELETE", authenticated: true))
        AccountSessionStore.shared.signOut()
    }

    static func stations(near coordinate: CLLocationCoordinate2D, fuel: FuelKind, radiusKm: Double = 8) async throws -> [FuelStation] {
        let boundedRadius = min(12, max(3, radiusKm))
        let path = String(format: "/api/navigation/fuel-stations?lat=%.6f&lon=%.6f&radius_km=%.1f&fuel=%@",
                          coordinate.latitude, coordinate.longitude, boundedRadius, fuel.apiValue)
        var stationRequest = try request(path: path)
        stationRequest.timeoutInterval = FuelStationQueryPolicy.requestTimeout
        let payload = try await data(for: stationRequest)
        return try JSONDecoder().decode(FuelStationEnvelope.self, from: payload).stations
    }

    static func askJarvis(_ message: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["message": message, "history": []])
        let payload = try await data(for: try request(path: "/api/jarvis/chat", method: "POST", body: body))
        let result = try JSONDecoder().decode(DriveChatResponse.self, from: payload)
        return result.reply ?? "Jarvis hat keine Antwort geliefert."
    }

    static func speedLimits(along points: [CLLocationCoordinate2D]) async throws -> [SpeedLimitResult] {
        guard !points.isEmpty else { return [] }
        let body = try JSONSerialization.data(withJSONObject: [
            "points": points.map { ["lat": $0.latitude, "lon": $0.longitude] },
        ])
        let payload = try await data(for: try request(path: "/api/navigation/speed-limits", method: "POST", body: body))
        return try JSONDecoder().decode(SpeedLimitEnvelope.self, from: payload).limits
    }

    static func tollCost(origin: String, destination: String, via: [String] = [],
                         avoidTolls: Bool = false) async throws -> TollCost {
        let body = try JSONEncoder().encode(TollSearchRequest(
            origin: origin, destination: destination, via: via, avoidTolls: avoidTolls
        ))
        var tollRequest = try request(path: "/api/navigation/toll-search", method: "POST", body: body)
        tollRequest.timeoutInterval = TollLookupRequestPolicy.timeout
        let payload = try await data(for: tollRequest)
        let result = try JSONDecoder().decode(TollSearchResponse.self, from: payload)
        if let evidence = TollEvidenceValidator.validate(
            status: result.status, amount: result.amount, currency: result.currency,
            source: result.source, sourceURL: result.sourceURL
        ) {
            return .known(amount: Decimal(evidence.amount), currency: evidence.currency, source: evidence.source)
        }
        if TollEvidenceValidator.validatesNoToll(
            status: result.status, source: result.source, sourceURL: result.sourceURL
        ) {
            return .noToll(source: result.source)
        }
        let titles = result.sources.prefix(3).map(\.title).joined(separator: " · ")
        return .unknown(reason: titles.isEmpty ? "SearXNG fand keinen eindeutig belegten Gesamtpreis." : "SearXNG geprüft: \(titles)")
    }

    static func publishRemoteState(_ state: DriveRemoteState) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        _ = try await data(for: try request(path: "/api/navigation/remote/state", method: "PUT",
                                            body: encoder.encode(state)))
    }

    static func remoteCommands() async throws -> [DriveRemoteCommand] {
        let payload = try await data(for: try request(path: "/api/navigation/remote/commands"))
        let decoder = JSONDecoder()
        return try decoder.decode(DriveRemoteCommandEnvelope.self, from: payload).commands
    }

    /// Lightweight authenticated end-to-end check used by the settings UI.
    /// Reading the command queue has no side effects and verifies both the
    /// standalone service and the signed-in account session.
    static func testConnection() async throws {
        _ = try await remoteCommands()
    }

    static func completeRemoteCommand(_ id: Int, ok: Bool, message: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ok": ok, "message": message as Any])
        _ = try await data(for: try request(path: "/api/navigation/remote/commands/\(id)/complete",
                                            method: "POST", body: body))
    }
}

enum ServerEndpointPolicy {
    static func url(baseURL: String, path: String) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "https" || (scheme == "http" && isPrivateHost(host)) else { return nil }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + suffix)
    }

    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        if octets[0] == 10 || octets[0] == 127 { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        // RFC 6598 shared space, used by Tailscale for tailnet addresses.
        if octets[0] == 100 && (64...127).contains(octets[1]) { return true }
        return false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct AccountCredentials: Encodable { let email: String; let password: String }
private struct AccountRegistrationCompletion: Encodable { let ticket: String }
private struct AccountRegistrationResponse: Decodable {
    let verificationTicket: String?
    enum CodingKeys: String, CodingKey { case verificationTicket = "verification_ticket" }
}
private struct AccountLoginRequest: Encodable {
    let email: String
    let password: String
    let totpCode: String?
    enum CodingKeys: String, CodingKey { case email, password; case totpCode = "totp_code" }
}

struct AccountLoginResponse: Decodable {
    let session: String
    let expiresAt: String
    let email: String
    let twoFactorEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case session, email
        case expiresAt = "expires_at"
        case twoFactorEnabled = "two_factor_enabled"
    }
}

struct AccountProfile: Decodable {
    let email: String
    let emailVerified: Bool
    let twoFactorEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case email
        case emailVerified = "email_verified"
        case twoFactorEnabled = "two_factor_enabled"
    }
}

struct TwoFactorSetup: Decodable {
    let secret: String
    let provisioningURI: String
    enum CodingKeys: String, CodingKey { case secret; case provisioningURI = "provisioning_uri" }
}

private struct TwoFactorCode: Encodable { let code: String }
private struct TwoFactorEnableResponse: Decodable {
    let recoveryCodes: [String]
    enum CodingKeys: String, CodingKey { case recoveryCodes = "recovery_codes" }
}

private struct TollSearchRequest: Encodable {
    let origin: String
    let destination: String
    let via: [String]
    let avoidTolls: Bool
    enum CodingKeys: String, CodingKey {
        case origin, destination, via
        case avoidTolls = "avoid_tolls"
    }
}
private struct TollSearchSource: Decodable { let title: String; let url: String; let snippet: String }
private struct TollSearchResponse: Decodable {
    let status: String
    let amount: Double?
    let currency: String
    let source: String
    let sourceURL: String?
    let sources: [TollSearchSource]

    enum CodingKeys: String, CodingKey {
        case status, amount, currency, source, sources
        case sourceURL = "source_url"
    }
}

enum TollEvidenceValidator {
    struct Evidence: Equatable { let amount: Double; let currency: String; let source: String }

    static func validate(status: String, amount: Double?, currency: String,
                         source: String, sourceURL: String?) -> Evidence? {
        let normalizedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard status == "known", let amount, amount.isFinite, amount > 0, amount <= 5_000,
              normalizedCurrency.count == 3,
              normalizedCurrency.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sourceURL, let url = URL(string: sourceURL), url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return Evidence(amount: amount, currency: normalizedCurrency, source: source)
    }


    static func validatesNoToll(status: String, source: String, sourceURL: String?) -> Bool {
        guard status == "no_toll",
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let sourceURL, let url = URL(string: sourceURL),
              url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return true
    }
}
