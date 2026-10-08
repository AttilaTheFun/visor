// What Visor says of the build installed here, for an updater app of the
// same team (one that installs its apps' builds over the air and shows
// which is installed): the version, the build number and the executable's
// UUID, in a keychain group the two share. Written at launch; Visor itself
// never reads it.

#if os(iOS)
import Foundation
import MachO
import Security

enum InstalledBuildReport {
    /// The shared group, after the team prefix, and the item's service;
    /// its account is the bundle id.
    static let group = "com.LoganShire.Installed"
    static let service = "installed-build"

    static func write() {
        guard let bundleID = Bundle.main.bundleIdentifier, let prefix = teamPrefix() else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let fields = ["bundleID": bundleID,
                      "version": info["CFBundleShortVersionString"] as? String ?? "",
                      "buildNumber": info["CFBundleVersion"] as? String ?? "",
                      "executableUUID": executableUUID() ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccessGroup as String: prefix + group,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: bundleID]
        var read = query
        read[kSecReturnData as String] = true
        var existing: AnyObject?
        if SecItemCopyMatching(read as CFDictionary, &existing) == errSecSuccess, existing as? Data == data { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// The UUID the linker gave this executable (its LC_UUID), as the
    /// updater reads it from the published build.
    static func executableUUID() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_UUID) {
                return UUID(uuid: cursor.loadUnaligned(as: uuid_command.self).uuid).uuidString
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }

    /// The team prefix of this app's keychain groups ("" in the
    /// simulator), from the group an item of its own lands in.
    private static func teamPrefix() -> String? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service + ".group",
                                    kSecAttrAccount as String: "probe",
                                    kSecReturnAttributes as String: true]
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = Data()
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let own = attributes[kSecAttrAccessGroup as String] as? String else { return nil }
        let first = own.split(separator: ".").first.map(String.init) ?? ""
        return first.count == 10 && first.allSatisfy { $0.isUppercase || $0.isNumber } ? first + "." : ""
    }
}
#endif
