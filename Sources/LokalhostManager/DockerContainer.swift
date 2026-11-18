import Foundation

struct DockerPort: Hashable {
    let host: HostBinding
    let destination: String

    var description: String {
        let address = host.family == "IPv6" ? "[\(host.host)]" : host.host
        return "\(address):\(host.port) → \(destination)"
    }
}

struct DockerContainer: Decodable, Identifiable {
    let id: String
    let name: String
    let state: String
    let project: String?
    let service: String?
    let number: String?
    let workingDirectory: String?
    let oneoff: Bool
    let ports: [DockerPort]

    private struct Address: Decodable { let HostIp: String, HostPort: String }
    private enum CodingKeys: CodingKey { case id, name, state, project, service, number, workingDirectory, oneoff, ports }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(String.self, forKey: .id)
        name = try data.decode(String.self, forKey: .name).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        state = try data.decode(String.self, forKey: .state)
        func label(_ key: CodingKeys) throws -> String? {
            guard let value = try data.decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
            return value
        }
        project = try label(.project)
        service = try label(.service)
        number = try label(.number)
        workingDirectory = try label(.workingDirectory).map(physicalDirectory)
        oneoff = try label(.oneoff)?.lowercased() == "true"
        let published = try data.decodeIfPresent([String: [Address]?].self, forKey: .ports) ?? [:]
        var ports = Set<DockerPort>()
        for (destination, bindings) in published where ["running", "paused", "restarting"].contains(state) {
            for binding in bindings ?? [] {
                guard let port = Int(binding.HostPort), (1...65535).contains(port), !binding.HostIp.isEmpty else { continue }
                let host = HostBinding(family: binding.HostIp.contains(":") ? "IPv6" : "IPv4", host: binding.HostIp, port: port)
                ports.insert(DockerPort(host: host, destination: destination))
            }
        }
        self.ports = ports.sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
    }

    var instanceDescription: String {
        guard let project, let service else { return "Einzelcontainer" }
        let instance = oneoff ? " · Einmallauf" : number.map { " · Instanz \($0)" } ?? ""
        return "\(project) / \(service)" + instance
    }

    var webTargets: [URL] {
        guard state == "running" else { return [] }
        return ports.compactMap { port in
            guard ["80/tcp", "443/tcp"].contains(port.destination) else { return nil }
            var host = port.host.host
            if host == "::" { host = "::1" }
            if host == "0.0.0.0" { host = "127.0.0.1" }
            if host.contains(":") { host = "[\(host)]" }
            let scheme = port.destination == "443/tcp" ? "https" : "http"
            guard let url = URL(string: "\(scheme)://\(host):\(port.host.port)"), WebTarget.accepts(url, on: [port.host]) else { return nil }
            return url
        }
    }
}
