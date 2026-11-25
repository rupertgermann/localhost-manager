import Darwin
import Foundation

struct ProcessIdentity: Hashable, Codable {
    var pid: pid_t
    var uid: uid_t
    var seconds: UInt64
    var microseconds: UInt64

    static func executable(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
    }

    static func read(_ pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, uid: info.pbi_uid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}

struct HostBinding: Hashable, Codable {
    var family: String
    var host: String
    var port: Int

    var description: String { "\(family)  \(host):\(port)" }

    func overlaps(_ other: HostBinding) -> Bool {
        guard port == other.port else { return false }
        if family == "*" || other.family == "*" { return true }
        let lhs = address, rhs = other.address
        if family == other.family { return lhs == rhs || lhs == "*" || rhs == "*" }
        // lsof does not report IPV6_V6ONLY for an IPv6 wildcard listener.
        let (v6, v4) = family == "IPv6" ? (lhs, rhs) : (rhs, lhs)
        if v6 == "*" { return true }
        guard v6.hasPrefix("::ffff:") else { return false }
        return v4 == "*" || v6.dropFirst("::ffff:".count) == v4
    }

    private var address: String {
        let value = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "0.0.0.0" || value == "*" { return "*" }
        guard family == "IPv6" else { return value }
        let parts = value.components(separatedBy: "%")
        var bytes = in6_addr()
        guard inet_pton(AF_INET6, parts[0], &bytes) == 1 else { return value }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &bytes, &buffer, socklen_t(buffer.count)) != nil else { return value }
        let ip = String(cString: buffer)
        if ip == "::" { return "*" }
        return parts.count == 2 ? ip + "%" + parts[1] : ip
    }
}

extension HostBinding {
    init(from decoder: Decoder) throws {
        // Older port snapshots did not record an address or address family.
        if let port = try? decoder.singleValueContainer().decode(Int.self) {
            self.init(family: "*", host: "*", port: port)
            return
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let family = try fields.decode(String.self, forKey: .family)
        let host = try fields.decode(String.self, forKey: .host)
        var address = in_addr()
        // lsof could report an IPv4 address under the IPv6 socket family.
        let mappedIPv4 = family == "IPv6" && inet_pton(AF_INET, host, &address) == 1
        try self.init(family: mappedIPv4 ? "IPv4" : family, host: host, port: fields.decode(Int.self, forKey: .port))
    }
}

struct LocalListener {
    var pid: pid_t
    var name: String
    var identity: ProcessIdentity?
    var directory: String?
    var executable: String?
    var bindings: [HostBinding] = []
    var hasNetworkDirectory = false

    static let dockerControlError = "Manage Docker port forwarding through its container."

    static func isDockerForwarder(_ executable: String?) -> Bool {
        executable?.hasSuffix("/Docker.app/Contents/MacOS/com.docker.backend") == true
    }

    var controlError: String? {
        if Self.isDockerForwarder(executable) { return Self.dockerControlError }
        guard executable != nil, let identity, identity.pid == pid, pid > 1, pid != getpid(), identity.uid == geteuid() else {
            return "Permission denied or the process identity could not be verified."
        }
        return nil
    }

    var isSystem: Bool {
        guard let executable else { return false }
        return executable.hasPrefix("/System/Library/") || executable.hasPrefix("/usr/libexec/")
    }
}

struct ManagerError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ListenerInventory {
    enum Visibility { case current, partial, unavailable }

    var listeners: [LocalListener]
    var warning: String?
    var visibility: Visibility = .current

    func requireCurrent() throws {
        guard visibility == .current else { throw ManagerError(warning ?? "Could not verify the listener inventory.") }
    }

    static func currentListeners(includeDirectories: Bool = false) async throws -> [LocalListener] {
        let inventory = includeDirectories ? try await scan() : try TCPListenerScan.inventory()
        try inventory.requireCurrent()
        return inventory.listeners
    }

    static func scan() async throws -> Self {
        var inventory = try TCPListenerScan.inventory()
        let volumes = LocalVolumes()
        for index in inventory.listeners.indices {
            var cwd = proc_vnodepathinfo()
            let size = Int32(MemoryLayout.size(ofValue: cwd))
            let pid = inventory.listeners[index].pid
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, size) == size else { continue }
            if volumes.isNetworkFileSystem(cwd.pvi_cdir.vip_vi.vi_fsid) {
                inventory.listeners[index].hasNetworkDirectory = true
                continue
            }
            let directory = withUnsafeBytes(of: &cwd.pvi_cdir.vip_path) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if volumes.isNetworkPath(directory) {
                inventory.listeners[index].hasNetworkDirectory = true
            } else if directory.hasPrefix("/") {
                inventory.listeners[index].directory = directory
            }
        }
        let incomplete = inventory.listeners.contains {
            !$0.hasNetworkDirectory && ($0.directory == nil || $0.identity == nil || $0.executable == nil)
        }
        if inventory.warning == nil && incomplete {
            inventory.warning = "Some processes have incomplete identity, executable or directory information."
        }
        return inventory
    }
}
