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
        try self.init(family: fields.decode(String.self, forKey: .family), host: fields.decode(String.self, forKey: .host),
                      port: fields.decode(Int.self, forKey: .port))
    }
}

struct LocalListener {
    var pid: pid_t
    var name: String
    var identity: ProcessIdentity?
    var directory: String?
    var executable: String?
    var bindings: [HostBinding] = []

    static let dockerControlError = "Docker-Portweiterleitung nur über den Container steuern."

    static func isDockerForwarder(_ executable: String?) -> Bool {
        executable?.hasSuffix("/Docker.app/Contents/MacOS/com.docker.backend") == true
    }

    var controlError: String? {
        if Self.isDockerForwarder(executable) { return Self.dockerControlError }
        guard executable != nil, let identity, identity.pid == pid, pid > 1, pid != getpid(), identity.uid == geteuid() else {
            return "Keine Berechtigung oder keine bestätigte Identität für diesen Prozess."
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
        guard visibility == .current else { throw ManagerError(warning ?? "Listenerbestand nicht bestätigt.") }
    }

    static func currentListeners() async throws -> [LocalListener] {
        let inventory = try await scan()
        try inventory.requireCurrent()
        return inventory.listeners
    }

    static func scan() async throws -> Self {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F0pcuftn"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let diagnostic = String(decoding: await stderr.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 || (process.terminationStatus == 1 && (diagnostic.isEmpty || !data.isEmpty)) else {
            throw ManagerError("Listener konnten nicht gelesen werden. " + diagnostic)
        }

        var listeners: [LocalListener] = []
        var family = ""
        for field in data.split(separator: 0) {
            let field = field.drop(while: { $0 == 10 })
            let value = String(decoding: field.dropFirst(), as: UTF8.self)
            switch field.first {
            case 112: // p
                guard let pid = pid_t(value) else { continue }
                var cwd = proc_vnodepathinfo()
                let size = Int32(MemoryLayout.size(ofValue: cwd))
                let directory = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, size) == size
                    ? withUnsafeBytes(of: &cwd.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } : nil
                let executable = ProcessIdentity.executable(of: pid)
                listeners.append(LocalListener(pid: pid, name: "Prozess \(pid)", identity: ProcessIdentity.read(pid), directory: directory.map(physicalDirectory), executable: executable))
            case 99 where !listeners.isEmpty: listeners[listeners.count - 1].name = value // c
            case 102: family = "" // f
            case 116: family = value // t
            case 110 where !listeners.isEmpty: // n
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let binding = HostBinding(family: family, host: String(value[..<colon]), port: port)
                if !listeners[listeners.count - 1].bindings.contains(binding) {
                    listeners[listeners.count - 1].bindings.append(binding)
                }
            default: break
            }
        }
        listeners.removeAll { $0.bindings.isEmpty }
        let incomplete = listeners.contains { $0.directory == nil || $0.identity == nil || $0.executable == nil }
        let warning = !diagnostic.isEmpty ? diagnostic : incomplete ? "Bei einigen Prozessen fehlen Angaben zu Identität, Programm oder Ordner." : nil
        let partial = !diagnostic.isEmpty || (process.terminationStatus != 0 && !data.isEmpty)
        return Self(listeners: listeners, warning: warning ?? (partial ? "Listenerbestand unvollständig." : nil),
                    visibility: partial ? .partial : .current)
    }
}
