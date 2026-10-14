import Foundation
import Security

/// The user never has to copy credentials into Kies Drive. After a normal
/// email/password login, the server-issued session is kept in Keychain and is
/// attached automatically to API requests.
public final class AccountSessionStore: ObservableObject {
    public static let shared = AccountSessionStore()
    @Published public private(set) var session: String?
    @Published public private(set) var email: String?
    @Published public private(set) var pendingRegistrationTicket: String?
    @Published public private(set) var pendingRegistrationEmail: String?

    private let service = "app.kies.drive.account-session"
    private let sessionAccount = "session"
    private let emailAccount = "email"
    private let pendingRegistrationTicketAccount = "pending-registration-ticket"
    private let pendingRegistrationEmailAccount = "pending-registration-email"

    private init() {
        session = Self.load(account: sessionAccount, service: service)
        email = Self.load(account: emailAccount, service: service)
        pendingRegistrationTicket = Self.load(account: pendingRegistrationTicketAccount, service: service)
        pendingRegistrationEmail = Self.load(account: pendingRegistrationEmailAccount, service: service)
        // Remove the retired manually provisioned device credential.
        Self.delete(account: "active-device-token", service: "app.kies.drive.device-token")
        UserDefaults.standard.removeObject(forKey: "drive.account.guestMode")
    }

    public func signIn(session: String, email: String) {
        Self.save(session, account: sessionAccount, service: service)
        Self.save(email, account: emailAccount, service: service)
        self.session = session
        self.email = email
        clearPendingRegistration()
    }

    public func beginRegistration(ticket: String, email: String) {
        Self.save(ticket, account: pendingRegistrationTicketAccount, service: service)
        Self.save(email, account: pendingRegistrationEmailAccount, service: service)
        pendingRegistrationTicket = ticket
        pendingRegistrationEmail = email
    }

    public func clearPendingRegistration() {
        Self.delete(account: pendingRegistrationTicketAccount, service: service)
        Self.delete(account: pendingRegistrationEmailAccount, service: service)
        pendingRegistrationTicket = nil
        pendingRegistrationEmail = nil
    }

    public func signOut() {
        Self.delete(account: sessionAccount, service: service)
        Self.delete(account: emailAccount, service: service)
        session = nil
        email = nil
    }

    private static func save(_ value: String, account: String, service: String) {
        delete(account: account, service: service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(account: String, service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private static func load(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
