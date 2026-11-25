// The screens of FEATURE_MAP.md, and how a test tells it is on each: the
// map's "You're there when", by identifier where the map names one.

import IsomerHeadless
import Testing

enum FeatureMapNode: String, CaseIterable, CustomTestStringConvertible {
    case onboarding, signIn, sessions, search, archived, project, migrate, addComputer
    case newSession, restore, folder, chat, approval, question, signInCode, model, allModels, details, toolCalls
    case preview, subPage, settings, computer, claudeSignIn, export
    case superCompact, superCompactRunning, superCompactReview, superCompactEdit, superCompactDone

    var testDescription: String { rawValue }

    /// Whether `screen` is this node, as FEATURE_MAP.md tells it.
    func isShown(on screen: HeadlessScreen) -> Bool {
        let sheet = !screen.presented.isEmpty
        switch self {
        case .onboarding: return screen.shows("Welcome to Visor")
        case .signIn: return screen.shows("Sign in to Visor")
        // The map's `computer-‹name›` and `session-‹id›`, or the list's Add
        // Computer, with nothing over them; or on the iPhone, its list
        // scrolled past both (on its side, or after an account's sign-in),
        // its title.
        case .sessions:
            return !sheet && (screen.elements.contains { $0.id?.hasPrefix("computer-") == true || $0.id?.hasPrefix("session-") == true }
                || (screen.has(id: "add-computer") && !screen.shows("Welcome to Visor") && !screen.has(id: "session-title"))
                || (screen.texts.last == "Sessions" && !screen.has(id: "session-title")))
        case .search: return screen.texts.contains("Messages") || screen.has(id: "message-hit")
        case .archived: return screen.shows("Archived Sessions")
        // The project's page, titled by its name: its own buttons.
        case .project: return screen.shows("Copy folder path") || screen.has(label: "Copy folder path")
        case .migrate: return screen.shows("Migrate")
        case .addComputer: return sheet && screen.has(id: "host") && screen.has(id: "connect")
        case .newSession: return sheet && screen.texts.contains("New Session")
        // New Session with Restore chosen: its Import… listed.
        case .restore: return sheet && screen.texts.contains("New Session") && screen.has(id: "import-archive")
        case .folder: return screen.texts.contains("Choose a folder")
        // Send, or with nothing typed on the iPhone, Dictate in its place;
        // or its slash commands offered, over it on the iPhone (a popover,
        // all the driver lists while it's open).
        case .chat:
            return (screen.has(id: "session-title") && (screen.element("Send") != nil || screen.has(label: "Dictate")))
                || screen.elements.contains { $0.label.hasPrefix("/goal") }
        case .approval: return (screen.has(id: "allow") && screen.has(id: "deny")) || screen.has(id: "answer")
        // `question-skip`; `question-send` too, enabled once an answer is
        // chosen.
        case .question: return sheet && (screen.has(id: "question-send") || screen.has(id: "question-skip"))
        case .signInCode: return sheet && (screen.shows("Paste the code Claude showed") || screen.has(id: "sign-in-paste"))
        case .model: return sheet && (screen.has(id: "all-models") || screen.has(id: "approval-Auto Approve"))
        case .allModels: return screen.has(id: "model-search")
        case .details: return screen.texts.contains("About")
        case .toolCalls: return screen.texts.contains("Tool calls")
        // Not in the map's table: a sheet, its Done and the picture.
        // (On the iPhone, Quick Look's: its close.)
        case .preview: return sheet && (screen.has(label: "Done") || screen.has(label: "close")) && !screen.texts.contains("Tool calls")
        case .subPage:
            return screen.texts.contains { $0 == "Side Questions" || $0.hasPrefix("Fork of") || $0.hasPrefix("Branch of") }
        case .settings: return screen.has(id: "settings-appearance")
        // Or its "Network paths": on the iPhone the page is taller than the
        // screen, and the driver lists what is on it.
        case .computer: return screen.has(id: "relay-toggle") || screen.has(id: "share-log") || screen.texts.contains("Network paths")
        // Sign In to Claude, for the computer's Sessions container: its
        // token's field and Save.
        case .claudeSignIn: return sheet && screen.has(id: "container-claude-token") && screen.has(id: "container-claude-save")
        // The export's sheet, reading, read or refused.
        case .export:
            return sheet && (screen.has(id: "export-progress") || screen.has(id: "export-save") || screen.has(id: "export-error"))
        // Super Compact's sheet: ready to start, running, HANDOFF.md for
        // review (and edited), and carried on.
        case .superCompact: return sheet && screen.has(id: "super-compact-start")
        case .superCompactRunning: return sheet && screen.has(id: "super-compact-progress") && screen.has(id: "super-compact-cancel")
        case .superCompactReview:
            return sheet && screen.has(id: "super-compact-cutover") && screen.has(id: "super-compact-edit") && screen.has(id: "super-compact-discard")
        case .superCompactEdit: return sheet && screen.has(id: "super-compact-editor") && screen.has(id: "super-compact-save")
        case .superCompactDone: return sheet && screen.has(id: "super-compact-continued")
        }
    }

    /// Expects `screen` to be this node, saying what it showed if not.
    func expectShown(on screen: HeadlessScreen, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isShown(on: screen), "not \(rawValue): \(screen.summary)", sourceLocation: sourceLocation)
    }
}
