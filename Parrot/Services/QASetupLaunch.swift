import Foundation
import CoreFoundation

/// Process-only setup for the exact isolated QA identity; never a readiness claim.
enum QASetupLaunch {
    enum Decision: Equatable, Sendable { case normal, settingsOnly, rejected }
    static func decision(arguments: [String], bundleID: String?, flag: Any?,
                         defaultFlag: Any? = nil, nextLaunch: Any? = nil) -> Decision {
        let options = Array(arguments.dropFirst())
        if AnswerTraceRecorder.isAllowed(bundleID: bundleID, flag: flag),
           defaultFlag != nil, boolean(defaultFlag) == nil { return .rejected }
        guard options.contains("--qa-setup") || options.contains("--qa-setup-self-check") || options.contains("--reviewed-selector-eval") else {
            if AnswerTraceRecorder.isAllowed(bundleID: bundleID, flag: flag),
               boolean(defaultFlag) == true {
                if boolean(nextLaunch) == false { return .normal }
                let gui = options.isEmpty || (options.count == 1 &&
                    options[0].range(of: #"^-psn_[0-9]+_[0-9]+$"#,options:.regularExpression) != nil)
                return gui || options == ["--query-startup-test"] ? .settingsOnly : .rejected
            }
            return .normal
        }
        let ownerProbe = options.count == 3 && options[0] == "--qa-setup" &&
            options[1] == "--qa-setup-self-check" && ["speech","speakers","local","embedding"].contains(options[2])
        let selectorProbe = options.count == 3 && options[0] == "--qa-setup" &&
            options[1] == "--reviewed-selector-eval" && options[2].hasPrefix("/")
        guard AnswerTraceRecorder.isAllowed(bundleID: bundleID, flag: flag),
              options == ["--qa-setup"] || options == ["--qa-setup", "--qa-setup-self-check"] || ownerProbe || selectorProbe else { return .rejected }
        return .settingsOnly
    }
    static let bundleID = "com.uygar.parrot.sat54.qa"
    static let nextLaunchKey = "qaSetupNextLaunch"
    /// Captured by ParrotMain before constructing any service. A settings
    /// button can change the NEXT launch only, never this process's guards.
    static let current: Decision = {
        let identity = Bundle.main.bundleIdentifier
        let flag = Bundle.main.object(forInfoDictionaryKey: "ParrotNativeAnswerTrace")
        let ownPreference = AnswerTraceRecorder.isAllowed(bundleID: identity, flag: flag)
            ? UserDefaults.standard.persistentDomain(forName: bundleID)?[nextLaunchKey] : nil
        return decision(arguments: CommandLine.arguments, bundleID: identity, flag: flag,
                 defaultFlag: Bundle.main.object(forInfoDictionaryKey: "ParrotQASetupByDefault"),
                 nextLaunch: ownPreference)
    }()
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    static var meetingModeNextTime: Bool {
        guard Bundle.main.bundleIdentifier == bundleID else { return false }
        return boolean(UserDefaults.standard.persistentDomain(forName: bundleID)?[nextLaunchKey]) == false
    }
    @discardableResult static func scheduleMeetingMode() -> Bool {
        guard isActive, Bundle.main.bundleIdentifier == bundleID else { return false }
        UserDefaults.standard.set(false, forKey: nextLaunchKey)
        return UserDefaults.standard.synchronize()
    }
    static var isActive: Bool { current == .settingsOnly }
    static var permitsMeetingWork: Bool { current == .normal }
    enum Unavailable: LocalizedError {
        case recording, model
        var errorDescription: String? {
            switch self {
            case .recording: "Recording is off in setup mode. Quit and reopen Parrot normally for meetings."
            case .model: "Models are off in setup mode. Quit and reopen Parrot normally to prepare them."
            }
        }
    }
}
