import Darwin
import Foundation

enum WebTarget {
    static func browserURL(for binding: HostBinding, saved: [URL], containerPort: String? = nil) -> URL? {
        guard (1...65535).contains(binding.port),
              containerPort == nil || containerPort?.hasSuffix("/tcp") == true else { return nil }
        if let url = saved.first(where: { accepts($0, on: [binding]) }) { return url }
        var host = binding.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["*", "0.0.0.0", "::"].contains(host) {
            host = binding.family == "IPv6" ? "::1" : "127.0.0.1"
        }
        var v4 = in_addr(), v6 = in6_addr()
        let address = host.components(separatedBy: "%")[0]
        guard inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        var parts = URLComponents()
        parts.scheme = binding.port == 443 || containerPort == "443/tcp" ? "https" : "http"
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = binding.port
        return parts.url
    }

    static func confirmed(_ text: String, existing: [URL], bindings: [HostBinding]) throws -> [URL] {
        var urls: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let address = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if address.isEmpty { continue }
            guard let url = URL(string: address), existing.contains(url) || accepts(url, on: bindings) else {
                throw ManagerError("Enter a local HTTP or HTTPS address with an active host port.")
            }
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    static func accepts(_ url: URL, on bindings: [HostBinding]) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, let rawHost = parts.host else { return false }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        var ip = in_addr()
        let ipv4Loopback = inet_pton(AF_INET, host, &ip) == 1 && UInt32(bigEndian: ip.s_addr) >> 24 == 127
        return bindings.contains { binding in
            guard binding.port == port else { return false }
            let bound = binding.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if bound == host && bound != "*" { return true }
            let wildcard = ["*", "0.0.0.0", "::"].contains(bound)
            if host == "localhost" { return wildcard || bound == "127.0.0.1" || bound == "::1" }
            return wildcard && ((binding.family == "IPv4" && ipv4Loopback) || (binding.family == "IPv6" && host == "::1"))
        }
    }
}
