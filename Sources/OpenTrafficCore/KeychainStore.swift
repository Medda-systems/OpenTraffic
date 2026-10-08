import Foundation
@preconcurrency import LocalAuthentication
import Security

public enum SecretReadAccess: Hashable, Sendable {
    case nonInteractive
    case userInitiated(reason: String)
}

public enum SecretStorageKind: Equatable, Sendable {
    case standard
    case userPresence
}

public enum SecretProtection: Equatable, Sendable {
    case standard
    case userPresence
}

public enum SecretMigrationResult: Equatable, Sendable {
    case migrated
    case migratedLegacyBackupRetained
}

public enum SecretStoreError: LocalizedError, Equatable, Sendable {
    case locked
    case cancelled
    case protectedStorageUnavailable
    case busy
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .locked:
            "The token is locked. Choose Unlock / Connect to authorize it once for this OpenTraffic session."
        case .cancelled:
            "Token authorization was cancelled."
        case .protectedStorageUnavailable:
            "Touch ID protected storage requires proper code signing plus the application-identifier and Keychain capability from suitable entitlements/provisioning. OpenTraffic did not fall back to unprotected storage."
        case .busy:
            "Another credential change is already in progress. Wait for it to finish and try again."
        case .keychain(let message):
            message
        }
    }
}

public protocol SecretStore: Sendable {
    func contains(key: String) throws -> Bool
    func storageKind(key: String) throws -> SecretStorageKind?
    func read(key: String, access: SecretReadAccess) throws -> String?
    func write(_ value: String, key: String, protection: SecretProtection) throws
    func migrateLegacyToUserPresence(key: String, value: String, reason: String) throws -> SecretMigrationResult
    func delete(key: String) throws
}

public struct KeychainStore: SecretStore, Sendable {
    public let service: String
    private let protectionRegistry: CredentialProtectionRegistry

    public init(
        service: String = "com.tunnelbar.app",
        protectionRegistry: CredentialProtectionRegistry = CredentialProtectionRegistry()
    ) {
        self.service = service
        self.protectionRegistry = protectionRegistry
    }

    public func contains(key: String) throws -> Bool {
        try storageKind(key: key) != nil
    }

    public func storageKind(key: String) throws -> SecretStorageKind? {
        if try protectionRegistry.isProtected(key: key) {
            let status = existenceStatus(key: key, usesDataProtection: true)
            if status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return .userPresence
            }
            if status == errSecMissingEntitlement || status == errSecNotAvailable {
                throw SecretStoreError.protectedStorageUnavailable
            }
            if status == errSecItemNotFound {
                throw SecretStoreError.keychain("The protected token record is missing. OpenTraffic did not fall back to legacy storage.")
            }
            try check(status)
        } else {
            let status = existenceStatus(key: key, usesDataProtection: false)
            if status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return .standard
            }
            if status == errSecItemNotFound { return nil }
            try check(status)
        }
        return nil
    }

    public func read(key: String, access: SecretReadAccess) throws -> String? {
        let usesDataProtection = try protectionRegistry.isProtected(key: key)
        return try readRecord(key: key, usesDataProtection: usesDataProtection, access: access)
    }

    public func write(_ value: String, key: String, protection: SecretProtection) throws {
        let data = Data(value.utf8)
        if let existingKind = try storageKind(key: key) {
            if protection == .userPresence, existingKind == .standard {
                throw SecretStoreError.keychain("The existing standard-Keychain token was preserved. Keep Standard Keychain with session unlock, or configure a properly signed build and migrate explicitly.")
            }
            let usesDataProtection = existingKind == .userPresence
            let query = baseQuery(key: key, usesDataProtection: usesDataProtection)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess {
                return
            }
            try check(status)
        }

        var insert: [String: Any]
        switch protection {
        case .standard:
            insert = baseQuery(key: key, usesDataProtection: false)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        case .userPresence:
            var accessError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &accessError
            ) else {
                throw SecretStoreError.keychain(accessError?.takeRetainedValue().localizedDescription ?? "Could not create Keychain access control.")
            }
            insert = baseQuery(key: key, usesDataProtection: true)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessControl as String] = accessControl
        }
        let status = SecItemAdd(insert as CFDictionary, nil)
        if protection == .userPresence, (status == errSecMissingEntitlement || status == errSecNotAvailable) {
            throw SecretStoreError.protectedStorageUnavailable
        }
        try check(status)
        if protection == .userPresence {
            do {
                try protectionRegistry.setProtected(true, key: key)
            } catch {
                SecItemDelete(baseQuery(key: key, usesDataProtection: true) as CFDictionary)
                throw error
            }
        }
    }

    public func migrateLegacyToUserPresence(
        key: String,
        value: String,
        reason: String
    ) throws -> SecretMigrationResult {
        guard try !protectionRegistry.isProtected(key: key) else { return .migrated }
        guard existenceStatus(key: key, usesDataProtection: false) != errSecItemNotFound else {
            throw SecretStoreError.keychain("The legacy token no longer exists. Nothing was migrated.")
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            throw SecretStoreError.keychain(accessError?.takeRetainedValue().localizedDescription ?? "Could not create Keychain access control.")
        }
        var candidate = baseQuery(key: key, usesDataProtection: true)
        candidate[kSecValueData as String] = Data(value.utf8)
        candidate[kSecAttrAccessControl as String] = accessControl
        let addStatus = SecItemAdd(candidate as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement || addStatus == errSecNotAvailable {
            throw SecretStoreError.protectedStorageUnavailable
        }
        try check(addStatus)

        do {
            let verified = try readRecord(
                key: key,
                usesDataProtection: true,
                access: .userInitiated(reason: reason)
            )
            guard verified == value else {
                throw SecretStoreError.keychain("Protected token verification returned different data. The legacy token was preserved.")
            }
            try protectionRegistry.setProtected(true, key: key)
        } catch {
            SecItemDelete(baseQuery(key: key, usesDataProtection: true) as CFDictionary)
            throw error
        }

        let legacyDelete = SecItemDelete(baseQuery(key: key, usesDataProtection: false) as CFDictionary)
        if legacyDelete == errSecSuccess || legacyDelete == errSecItemNotFound { return .migrated }
        return .migratedLegacyBackupRetained
    }

    public func delete(key: String) throws {
        if try protectionRegistry.isProtected(key: key) {
            let protectedStatus = SecItemDelete(baseQuery(key: key, usesDataProtection: true) as CFDictionary)
            if protectedStatus == errSecMissingEntitlement || protectedStatus == errSecNotAvailable {
                throw SecretStoreError.protectedStorageUnavailable
            }
            if protectedStatus != errSecSuccess && protectedStatus != errSecItemNotFound { try check(protectedStatus) }
            let legacyStatus = SecItemDelete(baseQuery(key: key, usesDataProtection: false) as CFDictionary)
            if legacyStatus != errSecSuccess && legacyStatus != errSecItemNotFound { try check(legacyStatus) }
            try protectionRegistry.setProtected(false, key: key)
        } else {
            let status = SecItemDelete(baseQuery(key: key, usesDataProtection: false) as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
    }

    private func existenceStatus(key: String, usesDataProtection: Bool) -> OSStatus {
        var query = baseQuery(key: key, usesDataProtection: usesDataProtection)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private func readRecord(
        key: String,
        usesDataProtection: Bool,
        access: SecretReadAccess
    ) throws -> String? {
        var query = baseQuery(key: key, usesDataProtection: usesDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = authenticationContext(for: access)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if usesDataProtection, (status == errSecMissingEntitlement || status == errSecNotAvailable) {
            throw SecretStoreError.protectedStorageUnavailable
        }
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw SecretStoreError.locked }
        if status == errSecUserCanceled { throw SecretStoreError.cancelled }
        try check(status)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func authenticationContext(for access: SecretReadAccess) -> LAContext {
        let context = LAContext()
        switch access {
        case .nonInteractive:
            context.interactionNotAllowed = true
        case .userInitiated(let reason):
            context.localizedReason = reason
        }
        return context
    }

    private func baseQuery(key: String, usesDataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if usesDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw SecretStoreError.keychain(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }
}

public protocol SessionAuthenticating: Sendable {
    func capability() async -> SessionAuthenticationCapability
    func authenticate(reason: String) async throws
}

public enum SessionAuthenticationCapability: Equatable, Sendable {
    case biometrics
    case deviceAuthentication
    case unavailable(String)
}

public struct LocalSessionAuthenticator: SessionAuthenticating, Sendable {
    public init() {}

    public func capability() async -> SessionAuthenticationCapability {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return .biometrics }
        error = nil
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return .deviceAuthentication }
        return .unavailable(error?.localizedDescription ?? "Device authentication is unavailable.")
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var capabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &capabilityError) else {
            throw SecretStoreError.keychain(capabilityError?.localizedDescription ?? "Device authentication is unavailable.")
        }
        do {
            let authenticated = try await withTaskCancellationHandler(
                operation: {
                    try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                },
                onCancel: { context.invalidate() }
            )
            guard authenticated else { throw SecretStoreError.cancelled }
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            throw SecretStoreError.cancelled
        } catch {
            throw SecretStoreError.keychain(error.localizedDescription)
        }
    }
}

public enum CredentialUnlockResult: Equatable, Sendable {
    case unlocked
    case missing
    case requiresLegacyAuthorization
}

public actor CredentialService {
    private let store: any SecretStore
    private let authenticator: any SessionAuthenticating
    private var cache: [String: String] = [:]
    private var inFlight: [RequestKey: ReadFlight] = [:]
    private var unlockInFlight: [String: UnlockFlight] = [:]
    private var legacySessionGates: Set<String> = []
    private var revisions: [String: UInt64] = [:]
    private var mutationsInFlight: Set<String> = []

    private struct RequestKey: Hashable {
        let key: String
        let access: SecretReadAccess
    }

    private struct ReadFlight {
        let id: UUID
        let revision: UInt64
        let task: Task<String?, Error>
    }

    private struct UnlockFlight {
        let id: UUID
        let revision: UInt64
        let task: Task<UnlockPayload, Error>
    }

    private struct UnlockPayload: Sendable {
        let result: CredentialUnlockResult
        let value: String?
        let authenticatedLegacySession: Bool
    }

    public init(store: any SecretStore, authenticator: any SessionAuthenticating = LocalSessionAuthenticator()) {
        self.store = store
        self.authenticator = authenticator
    }

    public func contains(key: String) -> Bool {
        if cache[key] != nil { return true }
        return (try? store.contains(key: key)) ?? false
    }

    public func authenticationCapability() async -> SessionAuthenticationCapability {
        await authenticator.capability()
    }

    public func storageKind(key: String) throws -> SecretStorageKind? {
        try store.storageKind(key: key)
    }

    public func cachedCredential(key: String) -> String? {
        cache[key]
    }

    public func credential(key: String, access: SecretReadAccess) async throws -> String? {
        if let cached = cache[key] { return cached }
        let requestKey = RequestKey(key: key, access: access)
        if let flight = inFlight[requestKey] {
            let value = try await flight.task.value
            guard revisions[key, default: 0] == flight.revision else { throw CancellationError() }
            return value
        }
        let store = self.store
        let revision = revisions[key, default: 0]
        let flightID = UUID()
        let task = Task.detached { try store.read(key: key, access: access) }
        inFlight[requestKey] = ReadFlight(id: flightID, revision: revision, task: task)
        defer {
            if inFlight[requestKey]?.id == flightID { inFlight[requestKey] = nil }
        }
        let value = try await task.value
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
        if let value { cache[key] = value }
        return value
    }

    public func unlock(key: String, reason: String) async throws -> CredentialUnlockResult {
        if cache[key] != nil { return .unlocked }
        if let flight = unlockInFlight[key] {
            let payload = try await flight.task.value
            return try applyUnlock(payload, key: key, revision: flight.revision)
        }

        let store = self.store
        let authenticator = self.authenticator
        let gateAlreadyOpen = legacySessionGates.contains(key)
        let revision = revisions[key, default: 0]
        let flightID = UUID()
        let task = Task.detached { () async throws -> UnlockPayload in
            guard let kind = try store.storageKind(key: key) else {
                return UnlockPayload(result: .missing, value: nil, authenticatedLegacySession: false)
            }
            switch kind {
            case .userPresence:
                let value = try store.read(key: key, access: .userInitiated(reason: reason))
                return UnlockPayload(result: value == nil ? .missing : .unlocked, value: value, authenticatedLegacySession: false)
            case .standard:
                if !gateAlreadyOpen { try await authenticator.authenticate(reason: reason) }
                do {
                    let value = try store.read(key: key, access: .nonInteractive)
                    return UnlockPayload(result: value == nil ? .missing : .unlocked, value: value, authenticatedLegacySession: true)
                } catch SecretStoreError.locked {
                    return UnlockPayload(result: .requiresLegacyAuthorization, value: nil, authenticatedLegacySession: true)
                }
            }
        }
        unlockInFlight[key] = UnlockFlight(id: flightID, revision: revision, task: task)
        defer {
            if unlockInFlight[key]?.id == flightID { unlockInFlight[key] = nil }
        }
        let payload = try await task.value
        return try applyUnlock(payload, key: key, revision: revision)
    }

    public func silentUnlock(key: String) async -> Bool {
        if cache[key] != nil { return true }
        guard (try? store.storageKind(key: key)) == .standard else { return false }
        do {
            guard let value = try store.read(key: key, access: .nonInteractive) else { return false }
            cache[key] = value
            legacySessionGates.insert(key)
            return true
        } catch {
            return false
        }
    }

    public func authorizeLegacy(key: String, reason: String) async throws -> CredentialUnlockResult {        guard legacySessionGates.contains(key) else {
            return try await unlock(key: key, reason: reason)
        }
        return try await credential(key: key, access: .userInitiated(reason: reason)) == nil ? .missing : .unlocked
    }

    public func save(_ value: String, key: String, protection: SecretProtection) async throws {
        guard mutationsInFlight.insert(key).inserted else { throw SecretStoreError.busy }
        defer { mutationsInFlight.remove(key) }
        invalidate(key: key)
        let revision = revisions[key, default: 0]
        let store = self.store
        try await Task.detached { try store.write(value, key: key, protection: protection) }.value
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
        cache[key] = value
        if protection == .standard { legacySessionGates.insert(key) }
    }

    public func migrateLegacyToUserPresence(key: String, reason: String) async throws -> SecretMigrationResult {
        guard let value = cache[key] else { throw SecretStoreError.locked }
        guard mutationsInFlight.insert(key).inserted else { throw SecretStoreError.busy }
        defer { mutationsInFlight.remove(key) }
        invalidate(key: key)
        let revision = revisions[key, default: 0]
        let store = self.store
        do {
            let result = try await Task.detached {
                try store.migrateLegacyToUserPresence(key: key, value: value, reason: reason)
            }.value
            guard revisions[key, default: 0] == revision else { throw CancellationError() }
            cache[key] = value
            return result
        } catch {
            if revisions[key, default: 0] == revision { cache[key] = value }
            throw error
        }
    }

    public func delete(key: String) async throws {
        guard mutationsInFlight.insert(key).inserted else { throw SecretStoreError.busy }
        defer { mutationsInFlight.remove(key) }
        invalidate(key: key)
        let revision = revisions[key, default: 0]
        let store = self.store
        try await Task.detached { try store.delete(key: key) }.value
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
    }

    public func clearSessionCache(key: String? = nil) {
        if let key {
            invalidate(key: key)
        } else {
            let keys = Set(cache.keys)
                .union(legacySessionGates)
                .union(unlockInFlight.keys)
                .union(inFlight.keys.map(\.key))
                .union(mutationsInFlight)
            for key in keys { invalidate(key: key) }
        }
    }

    private func applyUnlock(_ payload: UnlockPayload, key: String, revision: UInt64) throws -> CredentialUnlockResult {
        guard revisions[key, default: 0] == revision else { throw CancellationError() }
        if payload.authenticatedLegacySession { legacySessionGates.insert(key) }
        if let value = payload.value { cache[key] = value }
        return payload.result
    }

    private func invalidate(key: String) {
        revisions[key, default: 0] &+= 1
        cache[key] = nil
        legacySessionGates.remove(key)
        unlockInFlight[key]?.task.cancel()
        unlockInFlight[key] = nil
        let requests = inFlight.keys.filter { $0.key == key }
        for request in requests {
            inFlight[request]?.task.cancel()
            inFlight[request] = nil
        }
    }
}
