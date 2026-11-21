/// An app's own keychain access group, among those its signature's
/// entitlements give it: `<team>.<bundle id>`, as a Developer ID profile
/// grants it (`<team>.*`). Visor Client on the Mac keeps its secrets there,
/// in the data-protection keychain, when its build has one; a build signed
/// ad hoc has none.
public enum VisorKeychainGroup {
    /// The group of `groups`, else the application identifier, that is
    /// `<prefix>.<bundle id>`; nil without one.
    public static func own(bundleID: String, groups: [String], applicationIdentifier: String?) -> String? {
        let own = { (group: String) in group.hasSuffix("." + bundleID) && group.count > bundleID.count + 1 }
        return groups.first(where: own) ?? applicationIdentifier.flatMap { own($0) ? $0 : nil }
    }
}
