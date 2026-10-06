// What was being written to a session and not yet sent, kept as it is
// typed: backing out of the chat, switching sessions, or the app being
// put away loses nothing. One draft per computer and session, in the
// host's settings (the same store on every platform), gone when sent.

import VisorServices

@MainActor
public enum SavedDrafts {
    static func key(_ server: String, _ session: String) -> String { "draft." + server + "." + session }

    /// The draft kept for a session, or nothing.
    public static func draft(server: String, session: String) -> String {
        VisorHost.settings?.get(key: key(server, session)) ?? ""
    }

    /// Keeps a draft as it stands; an empty one is removed.
    public static func keep(_ draft: String, server: String, session: String) {
        VisorHost.settings?.set(key: key(server, session), value: draft)
    }

    public static func clear(server: String, session: String) {
        VisorHost.settings?.set(key: key(server, session), value: "")
    }
}
