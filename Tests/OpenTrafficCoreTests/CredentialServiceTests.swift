import Foundation
import Testing
@testable import OpenTrafficCore

private final class MockSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    var kind: SecretStorageKind? = .standard
    var value: String? = "secret"
    var lockNonInteractive = false
    var readDelayMicroseconds: useconds_t = 0
    private(set) var reads: [SecretReadAccess] = []
    private(set) var writes = 0
    var migrationResult: SecretMigrationResult = .migrated
    var migrationError: Error?
    var migrationDelayMicroseconds: useconds_t = 0
    private(set) var migrations = 0
    private(set) var deletes = 0
    private var started = 0

    /// A migration has reached the store (and is now in its delay).
    var migrationStarted: Bool { lock.withLock { started > 0 } }

    func contains(key: String) throws -> Bool { kind != nil }
    func storageKind(key: String) throws -> SecretStorageKind? { kind }

    func read(key: String, access: SecretReadAccess) throws -> String? {
        if readDelayMicroseconds > 0 { usleep(readDelayMicroseconds) }
        lock.lock()
        reads.append(access)
        let locked = lockNonInteractive && access == .nonInteractive
        let result = value
        lock.unlock()
        if locked { throw SecretStoreError.locked }
        return result
    }

    func write(_ value: String, key: String, protection: SecretProtection) throws {
        lock.lock()
        self.value = value
        kind = protection == .standard ? .standard : .userPresence
        writes += 1
        lock.unlock()
    }

    func migrateLegacyToUserPresence(key: String, value: String, reason: String) throws -> SecretMigrationResult {
        lock.withLock { started += 1 }
        if migrationDelayMicroseconds > 0 { usleep(migrationDelayMicroseconds) }
        lock.lock()
        defer { lock.unlock() }
        migrations += 1
        if let migrationError { throw migrationError }
        self.value = value
        kind = .userPresence
        return migrationResult
    }

    func delete(key: String) throws {
        lock.lock()
        deletes += 1
        value = nil
        kind = nil
        lock.unlock()
    }

    func readCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads.count
    }
}

@Test func concurrentSessionClearCannotResurrectMigratedTokenCache() async throws {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    // Long enough to stay under way while a busy machine (a full test run) gets to the next step.
    store.migrationDelayMicroseconds = 600_000
    let migration = Task { try await service.migrateLegacyToUserPresence(key: "token", reason: "Verify") }
    // Wait until it's really under way; a fixed pause loses the race on a busy machine.
    #expect(await eventually { store.migrationStarted })
    await service.clearSessionCache(key: "token")
    do {
        _ = try await migration.value
        Issue.record("Migration result should be cancelled after session clear")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await service.cachedCredential(key: "token") == nil)
}

@Test func overlappingCredentialMutationsAreRejected() async throws {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    // Long enough to stay under way while a busy machine (a full test run) gets to the next step.
    store.migrationDelayMicroseconds = 600_000
    let migration = Task { try await service.migrateLegacyToUserPresence(key: "token", reason: "Verify") }
    // Wait until it's really under way; a fixed pause loses the race on a busy machine.
    #expect(await eventually { store.migrationStarted })
    do {
        try await service.delete(key: "token")
        Issue.record("Overlapping delete should be rejected")
    } catch let error as SecretStoreError {
        #expect(error == .busy)
    }
    #expect(store.deletes == 0)
    #expect(try await migration.value == .migrated)
}

@Test func explicitMigrationUsesOnlyCachedTokenAndSelectsProtectedStorage() async throws {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    let readsBeforeMigration = store.readCount()
    #expect(try await service.migrateLegacyToUserPresence(key: "token", reason: "Verify") == .migrated)
    #expect(store.migrations == 1)
    #expect(store.readCount() == readsBeforeMigration)
    #expect(store.kind == .userPresence)
    #expect(await service.cachedCredential(key: "token") == "secret")
}

@Test func failedMigrationPreservesLegacySourceAndSessionCache() async throws {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    store.migrationError = SecretStoreError.cancelled
    do {
        _ = try await service.migrateLegacyToUserPresence(key: "token", reason: "Verify")
        Issue.record("Migration should fail")
    } catch {
        #expect(error is SecretStoreError)
    }
    #expect(store.kind == .standard)
    #expect(store.value == "secret")
    #expect(await service.cachedCredential(key: "token") == "secret")
}

@Test func migrationCanCommitProtectedPreferenceWhileRetainingLegacyBackup() async throws {
    let store = MockSecretStore()
    store.migrationResult = .migratedLegacyBackupRetained
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    #expect(try await service.migrateLegacyToUserPresence(key: "token", reason: "Verify") == .migratedLegacyBackupRetained)
    #expect(store.kind == .userPresence)
    #expect(await service.cachedCredential(key: "token") == "secret")
}

private actor MockAuthenticator: SessionAuthenticating {
    private(set) var count = 0

    func capability() async -> SessionAuthenticationCapability { .biometrics }

    func authenticate(reason: String) async throws {
        count += 1
        try await Task.sleep(for: .milliseconds(40))
    }

    func authenticationCount() -> Int { count }
}

@Test func presenceAndCacheChecksNeverReadCredentialBytes() async {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    #expect(await service.contains(key: "token"))
    #expect(await service.cachedCredential(key: "token") == nil)
    #expect(store.readCount() == 0)
}

@Test func concurrentLegacyUnlockCoalescesAuthenticationAndRead() async throws {
    let store = MockSecretStore()
    let authenticator = MockAuthenticator()
    let service = CredentialService(store: store, authenticator: authenticator)
    async let first = service.unlock(key: "token", reason: "Unlock")
    async let second = service.unlock(key: "token", reason: "Unlock")
    #expect(try await first == .unlocked)
    #expect(try await second == .unlocked)
    #expect(await authenticator.authenticationCount() == 1)
    #expect(store.readCount() == 1)
    #expect(await service.cachedCredential(key: "token") == "secret")
}

@Test func legacyAuthorizationDoesNotRepeatSessionAuthentication() async throws {
    let store = MockSecretStore()
    store.lockNonInteractive = true
    let authenticator = MockAuthenticator()
    let service = CredentialService(store: store, authenticator: authenticator)
    #expect(try await service.unlock(key: "token", reason: "Unlock") == .requiresLegacyAuthorization)
    #expect(await authenticator.authenticationCount() == 1)
    #expect(try await service.authorizeLegacy(key: "token", reason: "Authorize") == .unlocked)
    #expect(await authenticator.authenticationCount() == 1)
    #expect(try await service.unlock(key: "token", reason: "Unlock") == .unlocked)
    #expect(await authenticator.authenticationCount() == 1)
}

@Test func staleReadCannotOverwriteNewlySavedCredential() async throws {
    let store = MockSecretStore()
    store.readDelayMicroseconds = 120_000
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    let oldRead = Task { try await service.credential(key: "token", access: .nonInteractive) }
    let joinedRead = Task { try await service.credential(key: "token", access: .nonInteractive) }
    try await Task.sleep(for: .milliseconds(15))
    try await service.save("new-secret", key: "token", protection: .standard)
    do {
        _ = try await oldRead.value
        Issue.record("Invalidated original read should be cancelled")
    } catch {
        #expect(error is CancellationError)
    }
    do {
        _ = try await joinedRead.value
        Issue.record("Invalidated joined read should be cancelled")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await service.cachedCredential(key: "token") == "new-secret")
}

@Test func invalidationCancelsOriginalAndJoinedUnlockWaiters() async throws {
    let store = MockSecretStore()
    let authenticator = MockAuthenticator()
    let service = CredentialService(store: store, authenticator: authenticator)
    let first = Task { try await service.unlock(key: "token", reason: "Unlock") }
    let joined = Task { try await service.unlock(key: "token", reason: "Unlock") }
    try await Task.sleep(for: .milliseconds(5))
    await service.clearSessionCache(key: "token")

    for task in [first, joined] {
        do {
            _ = try await task.value
            Issue.record("Invalidated unlock should be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
    }
    #expect(await service.cachedCredential(key: "token") == nil)
    #expect(await authenticator.authenticationCount() == 1)
}

@Test func silentUnlockLoadsStandardTokenWithoutAuthentication() async {
    let store = MockSecretStore()
    let authenticator = MockAuthenticator()
    let service = CredentialService(store: store, authenticator: authenticator)
    #expect(await service.silentUnlock(key: "token") == true)
    #expect(await service.cachedCredential(key: "token") == "secret")
    #expect(await authenticator.authenticationCount() == 0)
    #expect(store.readCount() == 1)
}

@Test func silentUnlockFailsClosedForUserPresenceTokens() async {
    let store = MockSecretStore()
    store.kind = .userPresence
    let authenticator = MockAuthenticator()
    let service = CredentialService(store: store, authenticator: authenticator)
    #expect(await service.silentUnlock(key: "token") == false)
    #expect(await service.cachedCredential(key: "token") == nil)
    #expect(await authenticator.authenticationCount() == 0)
    #expect(store.readCount() == 0)
}

@Test func silentUnlockFailsClosedWhenKeychainNeedsAuthorization() async {
    let store = MockSecretStore()
    store.lockNonInteractive = true
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    #expect(await service.silentUnlock(key: "token") == false)
    #expect(await service.cachedCredential(key: "token") == nil)
}

@Test func silentUnlockReportsMissingTokens() async {
    let store = MockSecretStore()
    store.kind = nil
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    #expect(await service.silentUnlock(key: "token") == false)
}

@Test func silentUnlockPrefersSessionCache() async throws {
    let store = MockSecretStore()
    let service = CredentialService(store: store, authenticator: MockAuthenticator())
    _ = try await service.unlock(key: "token", reason: "Unlock")
    store.kind = nil
    #expect(await service.silentUnlock(key: "token") == true)
}
