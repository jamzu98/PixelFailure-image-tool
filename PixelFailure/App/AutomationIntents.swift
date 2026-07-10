import AppIntents
import AppKit
import Foundation

@MainActor
final class AutomationBridge {
    static let shared = AutomationBridge()
    weak var activeDocument: PixelDocument?

    @discardableResult
    func run(actionJSON: String) throws -> String {
        let action = try JSONDecoder().decode(RecordedAction.self, from: Data(actionJSON.utf8))
        guard let activeDocument else { throw CocoaError(.userCancelled) }
        activeDocument.update(nil, actionName: action.name) {
            ActionExecutor.apply(action, to: &$0)
        }
        return "Applied \(action.steps.count) steps from \(action.name)."
    }
}

/// Available in Shortcuts and Spotlight. The same JSON action payload is used
/// by the in-app recorder, batch processor, and AppleScript command.
struct RunPixelFailureActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run PixelFailure Action"
    static let description = IntentDescription("Applies a recorded PixelFailure action to the front document.")
    static let openAppWhenRun = true

    @Parameter(title: "Action JSON")
    var actionJSON: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try AutomationBridge.shared.run(actionJSON: actionJSON)
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// `tell application "PixelFailure" to run action "{...}"`
@objc(PFRunActionCommand)
nonisolated final class PFRunActionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let json = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "A recorded-action JSON string is required."
            return nil
        }
        do {
            return try MainActor.assumeIsolated {
                try AutomationBridge.shared.run(actionJSON: json)
            }
        } catch {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
