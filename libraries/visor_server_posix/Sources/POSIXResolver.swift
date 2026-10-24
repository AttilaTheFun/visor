import Foundation

/// A name's IPv4 address, as this computer resolves it (getaddrinfo, which
/// on a Mac includes `.local` names): for those who cannot resolve it
/// themselves, such as an agent in a container.
public enum POSIXResolver {
    public static func ipv4(_ name: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &found) == 0, let first = found else { return nil }
        defer { freeaddrinfo(found) }
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ok = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                var raw = inet.pointee.sin_addr
                return inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) != nil
            }
            if ok { return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        return nil
    }
}
