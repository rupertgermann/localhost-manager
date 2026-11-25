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
    let containerDirectory: String?
    let mountedWorkingDirectory: String?
    let oneoff: Bool
    let ports: [DockerPort]

    private struct Address: Decodable { let HostIp: String, HostPort: String }
    private struct Mount: Decodable {
        let type: String
        let source: String?
        let destination: String
        enum CodingKeys: String, CodingKey {
            case type = "Type", source = "Source", destination = "Destination"
        }
    }
    private enum CodingKeys: CodingKey { case id, name, state, project, service, number, workingDirectory, containerDirectory, mounts, oneoff, ports }

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
        containerDirectory = try data.decodeIfPresent(String.self, forKey: .containerDirectory).map { $0.isEmpty ? "/" : $0 }
        let mounts = try data.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
        let volumes = LocalVolumes()
        mountedWorkingDirectory = Self.hostPath(for: containerDirectory, in: mounts).flatMap { volumes.isNetworkPath($0) ? nil : $0 }
        workingDirectory = try label(.workingDirectory).flatMap(volumes.resolveLocalPath)
        oneoff = try label(.oneoff)?.lowercased() == "true"
        let published = try data.decodeIfPresent([String: [Address]?].self, forKey: .ports) ?? [:]
        var ports = Set<DockerPort>()
        for (destination, bindings) in published where Self.isActive(state) {
            for binding in bindings ?? [] {
                guard let port = Int(binding.HostPort), (1...65535).contains(port), !binding.HostIp.isEmpty else { continue }
                let host = HostBinding(family: binding.HostIp.contains(":") ? "IPv6" : "IPv4", host: binding.HostIp, port: port)
                ports.insert(DockerPort(host: host, destination: destination))
            }
        }
        self.ports = ports.sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending }
    }

    private static func hostPath(for directory: String?, in mounts: [Mount]) -> String? {
        guard let directory, directory.hasPrefix("/") else { return nil }
        let parts = directory.split(separator: "/")
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        // A nested volume hides the same directory in its parent bind mount.
        let mount = mounts.filter { parts.starts(with: $0.destination.split(separator: "/")) }
            .max { $0.destination.count < $1.destination.count }
        guard let mount, mount.type == "bind", let source = mount.source, source.hasPrefix("/") else { return nil }
        return parts.dropFirst(mount.destination.split(separator: "/").count).reduce(source) {
            ($0 as NSString).appendingPathComponent(String($1))
        }
    }

    var instanceDescription: String {
        guard let project, let service else { return "Standalone container" }
        let instance = oneoff ? " · One-off" : number.map { " · Instance \($0)" } ?? ""
        return "\(project) / \(service)" + instance
    }

    static func isActive(_ state: String) -> Bool {
        ["running", "paused", "restarting"].contains(state)
    }
}
