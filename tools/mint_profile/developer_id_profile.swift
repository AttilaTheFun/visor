// Makes (or fetches) the Developer ID provisioning profile for a Mac app
// through the App Store Connect API, with the API key in
// ~/.appstoreconnect/visor.env, and saves it where Xcode keeps profiles.
// For when Xcode's own export cannot (its cloud signing wants an Admin key).
// The profile names every Developer ID Application certificate of the team,
// so each of the team's Macs can sign with it; one that already does is
// fetched rather than replaced (`--replace` makes it anew).
// The App ID must exist with its capabilities (mint_mac_profile.sh's archive
// step registers it).
//
//   swiftc -parse-as-library tools/mint_profile/developer_id_profile.swift -o /tmp/developer_id_profile
//   /tmp/developer_id_profile <bundle id> [--replace]

import CryptoKit
import Foundation

func env(_ name: String) -> String {
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
    let file = (try? String(contentsOfFile: NSHomeDirectory() + "/.appstoreconnect/visor.env", encoding: .utf8)) ?? ""
    for line in file.split(separator: "\n") where line.hasPrefix(name + "=") {
        return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }
    fatalError("No \(name) in the environment or ~/.appstoreconnect/visor.env")
}

func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func call(_ jwt: String, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer " + jwt, forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    guard (200..<300).contains(status) else {
        let detail = ((object["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? String(decoding: data, as: UTF8.self)
        throw NSError(domain: "ASC", code: status, userInfo: [NSLocalizedDescriptionKey: "\(method) \(path): \(status) \(detail)"])
    }
    return object
}

/// A serial as both sides can agree on: upper case, no leading zeros
/// (openssl keeps them; App Store Connect does not).
func normalized(_ serial: String) -> String {
    let upper = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let trimmed = upper.drop { $0 == "0" }
    return trimmed.isEmpty ? "0" : String(trimmed)
}

/// The serial numbers of the Developer ID Application certificates in this keychain.
func localSerials() -> Set<String> {
    let pipe = Pipe()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-certificate", "-a", "-p", "-c", "Developer ID Application"]
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let pems = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var serials = Set<String>()
    for block in pems.components(separatedBy: "-----END CERTIFICATE-----") where block.contains("BEGIN") {
        let o = Pipe(), i = Pipe()
        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        s.arguments = ["x509", "-noout", "-serial"]
        s.standardInput = i; s.standardOutput = o
        try? s.run()
        i.fileHandleForWriting.write(Data((block + "-----END CERTIFICATE-----\n").utf8)); i.fileHandleForWriting.closeFile()
        s.waitUntilExit()
        let line = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let serial = line.split(separator: "=").last { serials.insert(normalized(String(serial))) }
    }
    return serials
}

@main
struct DeveloperIDProfile {
    static func main() async throws {
        let bundle = CommandLine.arguments.dropFirst().first ?? { fatalError("bundle id") }()
        let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: env("VISOR_ASC_KEY_PATH"), encoding: .utf8))
        let now = Int(Date().timeIntervalSince1970)
        let header = b64url(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": env("VISOR_ASC_KEY_ID"), "typ": "JWT"]))
        let claims = b64url(try JSONSerialization.data(withJSONObject: ["iss": env("VISOR_ASC_ISSUER_ID"), "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"]))
        let jwt = header + "." + claims + "." + b64url(try key.signature(for: Data((header + "." + claims).utf8)).rawRepresentation)
        let name = "Visor Developer ID: " + bundle
        let bundles = try await call(jwt, "GET", "/v1/bundleIds?filter%5Bidentifier%5D=" + bundle)
        guard let bundleID = ((bundles["data"] as? [[String: Any]]) ?? []).first(where: {
            (($0["attributes"] as? [String: Any])?["identifier"] as? String) == bundle })?["id"] as? String else {
            fatalError("No App ID \(bundle): run mint_mac_profile.sh first, which registers it")
        }
        // Every Developer ID Application certificate the team has, not only
        // this Mac's: a profile names the certificates it is good for, and a
        // build signed on another of the team's Macs embeds the same profile.
        let certificates = try await call(jwt, "GET", "/v1/certificates?filter%5BcertificateType%5D=DEVELOPER_ID_APPLICATION&limit=50")
        let team = (certificates["data"] as? [[String: Any]]) ?? []
        let ids = Set(team.compactMap { $0["id"] as? String })
        let serials = localSerials()
        let here = team.contains { serials.contains(normalized((($0["attributes"] as? [String: Any])?["serialNumber"] as? String) ?? "")) }
        guard !ids.isEmpty else { fatalError("The team has no Developer ID Application certificate") }
        if !here { print("Note: none of the team's \(ids.count) Developer ID certificates is in this keychain; this Mac cannot sign with the profile.") }

        // One already made under this name is kept when it names all of
        // them (so the Macs share one profile and none replaces another's),
        // and replaced when it does not, or when asked to (`--replace`: it
        // may predate a capability).
        let replace = CommandLine.arguments.contains("--replace")
        let existing = try await call(jwt, "GET", "/v1/profiles?include=certificates&filter%5Bname%5D=" + (name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name))
        for profile in (existing["data"] as? [[String: Any]]) ?? [] {
            guard let id = profile["id"] as? String else { continue }
            let named = Set(((((profile["relationships"] as? [String: Any])?["certificates"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
            let attributes = profile["attributes"] as? [String: Any] ?? [:]
            if !replace, named.isSuperset(of: ids), attributes["profileState"] as? String == "ACTIVE" {
                try save(attributes, named: name, note: "already names the team's \(ids.count) certificate\(ids.count == 1 ? "" : "s")")
                return
            }
            _ = try? await call(jwt, "DELETE", "/v1/profiles/" + id)
        }
        let made = try await call(jwt, "POST", "/v1/profiles", ["data": [
            "type": "profiles",
            "attributes": ["name": name, "profileType": "MAC_APP_DIRECT"],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleID]],
                "certificates": ["data": ids.sorted().map { ["type": "certificates", "id": $0] }],
            ],
        ]])
        guard let attributes = (made["data"] as? [String: Any])?["attributes"] as? [String: Any] else {
            fatalError("The profile came back without its attributes")
        }
        try save(attributes, named: name, note: "made for the team's \(ids.count) certificate\(ids.count == 1 ? "" : "s")")
    }

    /// Writes a profile's content where Xcode keeps profiles, under its UUID.
    static func save(_ attributes: [String: Any], named name: String, note: String) throws {
        guard let content = attributes["profileContent"] as? String, let data = Data(base64Encoded: content),
              let uuid = attributes["uuid"] as? String else { fatalError("The profile came back without its content") }
        let folder = NSHomeDirectory() + "/Library/Developer/Xcode/UserData/Provisioning Profiles"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = folder + "/" + uuid + ".provisionprofile"
        try data.write(to: URL(fileURLWithPath: path))
        print("Saved \"\(name)\" (\(note)) to \(path)")
    }
}
