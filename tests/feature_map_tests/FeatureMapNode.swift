// The screens of FEATURE_MAP.md, and how a test tells it is on each: the
// map's "You're there when", by identifier where the map names one.

import IsomerHeadless
import Testing

enum FeatureMapNode: String, CaseIterable, CustomTestStringConvertible {
    case onboarding, signIn, sessions, search, archived, project, migrate, addComputer, runner
    case newSession, folder, chat, approval, question, model, allModels, details, toolCalls
    case preview, subPage, settings, computer

    var testDescription: String { rawValue }

    /// Whether `screen` is this node, as FEATURE_MAP.md tells it.
    func isShown(on screen: HeadlessScreen) -> Bool {
        let sheet = !screen.presented.isEmpty
        switch self {
        case .onboarding: return screen.shows("Welcome to Visor")
        case .signIn: return screen.shows("Sign in to Visor")
        // The map's `computer-‹name›` and `session-‹id›` (IsomerGap
        // .combinedElement, .listRow): where neither is listed, the list
        // and its Add Computer with nothing over them.
        case .sessions:
            return !sheet && (screen.elements.contains { $0.id?.hasPrefix("computer-") == true || $0.id?.hasPrefix("session-") == true }
                || (screen.has(id: "add-computer") && !screen.shows("Welcome to Visor") && !screen.has(id: "session-title")))
        case .search: return screen.texts.contains("Messages") || screen.has(id: "message-hit")
        case .archived: return screen.shows("Archived Sessions")
        case .project: return screen.shows("Project Settings")
        case .migrate: return screen.shows("Migrate")
        case .addComputer: return sheet && screen.has(id: "host") && screen.has(id: "connect")
        case .runner: return screen.has(id: "multipass-code") || screen.has(id: "runner-url")
        case .newSession: return sheet && screen.texts.contains("New Session")
        case .folder: return screen.texts.contains("Choose a folder")
        case .chat: return screen.has(id: "session-title") && screen.element("Send") != nil
        // `allow` and `deny`, or `answer` (IsomerGap.wrappedControl: by
        // their labels where those aren't listed).
        case .approval:
            return (screen.has(id: "allow") && screen.has(id: "deny")) || screen.has(id: "answer")
                || (screen.has(label: "Allow") && screen.has(label: "Deny")) || screen.has(label: "Answer")
        // The map's `question-send` is listed once an answer is chosen
        // (Isomer's driver leaves a disabled bar item out); `question-skip`
        // always.
        case .question: return sheet && (screen.has(id: "question-send") || screen.has(id: "question-skip"))
        case .model: return sheet && (screen.has(id: "all-models") || screen.has(id: "approval-Auto Approve"))
        case .allModels: return screen.has(id: "model-search")
        case .details: return screen.texts.contains("About")
        case .toolCalls: return screen.texts.contains("Tool calls")
        // Not in the map's table: a sheet, its Done and the picture.
        case .preview: return sheet && screen.has(label: "Done") && !screen.texts.contains("Tool calls")
        case .subPage:
            return screen.texts.contains { $0 == "Side Questions" || $0.hasPrefix("Fork of") || $0.hasPrefix("Branch of") }
        case .settings: return screen.has(id: "settings-appearance")
        // The map's `relay-toggle` (IsomerGap.toggle): where it isn't
        // listed, the page's Share Connection Log.
        case .computer: return screen.has(id: "relay-toggle") || screen.has(id: "share-log")
        }
    }

    /// Expects `screen` to be this node, saying what it showed if not.
    func expectShown(on screen: HeadlessScreen, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isShown(on: screen), "not \(rawValue): \(screen.summary)", sourceLocation: sourceLocation)
    }
}
