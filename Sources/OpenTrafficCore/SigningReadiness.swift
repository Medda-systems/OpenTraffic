import Foundation
import Security

public struct SigningReadiness: Equatable, Sendable {
    public let isReadyForProtectedKeychain: Bool
    public let teamIdentifier: String?
    public let applicationIdentifier: String?
    public let keychainAccessGroups: [String]
    public let message: String

    public init(
        isReadyForProtectedKeychain: Bool,
        teamIdentifier: String?,
        applicationIdentifier: String?,
        keychainAccessGroups: [String],
        message: String
    ) {
        self.isReadyForProtectedKeychain = isReadyForProtectedKeychain
        self.teamIdentifier = teamIdentifier
        self.applicationIdentifier = applicationIdentifier
        self.keychainAccessGroups = keychainAccessGroups
        self.message = message
    }
}

public enum SigningReadinessInspector {
    public static func current() -> SigningReadiness {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return notReady("Could not inspect the running code signature.")
        }
        guard SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            return notReady("The running code signature is invalid under strict validation.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return notReady("Could not inspect the static code signature.")
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
        let info = signingInfo as? [CFString: Any] else {
            return notReady("Could not read cryptographic signing information.")
        }
        let flags = (info[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let adHocSignatureFlag: UInt32 = 0x0002 // CS_ADHOC from Security/CSCommon.h; not imported into Swift.
        guard flags & adHocSignatureFlag == 0 else {
            return notReady("This is an ad-hoc signed build. A legitimate non-ad-hoc signing identity and provisioning setup are required.")
        }
        guard let task = SecTaskCreateFromSelf(nil) else {
            return notReady("Could not inspect the running code signature.")
        }
        let team = entitlement("com.apple.developer.team-identifier", task: task) as? String
        let application = entitlement("com.apple.application-identifier", task: task) as? String
        let groups = entitlement("keychain-access-groups", task: task) as? [String] ?? []
        guard let team, !team.isEmpty else {
            return notReady("This build has no valid Team identifier. Install and select a legitimate signing identity and provisioning setup.")
        }
        guard let application, !application.isEmpty else {
            return SigningReadiness(
                isReadyForProtectedKeychain: false,
                teamIdentifier: team,
                applicationIdentifier: nil,
                keychainAccessGroups: groups,
                message: "The signature lacks com.apple.application-identifier. Add the Keychain capability through the legitimate signing/provisioning configuration."
            )
        }
        return SigningReadiness(
            isReadyForProtectedKeychain: true,
            teamIdentifier: team,
            applicationIdentifier: application,
            keychainAccessGroups: groups,
            message: groups.isEmpty
                ? "Signing and the default application identifier are available for protected Keychain storage."
                : "Signing and Keychain access groups are available for protected Keychain storage."
        )
    }

    private static func entitlement(_ name: String, task: SecTask) -> Any? {
        SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    private static func notReady(_ message: String) -> SigningReadiness {
        SigningReadiness(
            isReadyForProtectedKeychain: false,
            teamIdentifier: nil,
            applicationIdentifier: nil,
            keychainAccessGroups: [],
            message: message
        )
    }
}
