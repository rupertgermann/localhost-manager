import Darwin
import Foundation

/// Identities observed before stopping survive a manager quit in the middle of a restart.
struct Predecessor: Codable {
    var processes: Set<ProcessIdentity>
    var ports: Set<Int>
    var supervisor: ProcessIdentity?
    var processGroup: pid_t?

    func checkPorts(_ listeners: [LocalListener], excluding owned: Set<ProcessIdentity> = []) throws {
        for listener in listeners where listener.identity.map(owned.contains) != true {
            if let binding = listener.bindings.first(where: { ports.contains($0.port) }) {
                throw ManagerError("Port \(binding.port) weiterhin belegt durch \(listener.name) (PID \(listener.pid)).")
            }
        }
    }

    var hasLiveProcesses: Bool {
        if processes.contains(where: { ProcessIdentity.read($0.pid) == $0 }) { return true }
        guard let processGroup else { return false }
        return kill(-processGroup, 0) == 0 || errno == EPERM
    }

    func checkEnded() throws {
        if hasLiveProcesses { throw ManagerError("Der vorherige Prozess oder eines seiner Kinder läuft noch.") }
        try checkSupervisor()
    }

    func checkSupervisor() throws {
        if let supervisor, ProcessIdentity.read(supervisor.pid) == supervisor {
            throw ManagerError("Der übergeordnete Starter oder Watcher läuft noch. Bitte zuerst im Terminal beenden.")
        }
    }

    static func tree(_ root: ProcessIdentity) throws -> Set<ProcessIdentity> {
        var found: Set<ProcessIdentity> = [root], pending = [root]
        while let parent = pending.popLast() {
            var pids = [pid_t](repeating: 0, count: 32)
            while true {
                let capacity = pids.count * MemoryLayout<pid_t>.stride
                let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent.pid), &pids, Int32(capacity))
                guard bytes >= 0 else { throw ManagerError("Prozesskinder konnten nicht geprüft werden.") }
                if Int(bytes) == capacity { pids += Array(repeating: 0, count: pids.count); continue }
                for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride) {
                    if let child = ProcessIdentity.read(pid), found.insert(child).inserted { pending.append(child) }
                }
                break
            }
        }
        guard ProcessIdentity.read(root.pid) == root else { throw ManagerError("Die Prozessidentität hat sich geändert.") }
        return found
    }

    // An interactive job-control shell can outlive its foreground command. Other launchers may respawn it.
    static func supervisor(of root: ProcessIdentity) throws -> ProcessIdentity? {
        var child = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: child))
        guard proc_pidinfo(root.pid, PROC_PIDTBSDINFO, 0, &child, size) == size,
              ProcessIdentity.read(root.pid) == root else { throw ManagerError("Der Starter ist nicht eindeutig feststellbar.") }
        let parent = pid_t(child.pbi_ppid)
        if parent == 1 { return nil }
        guard let identity = ProcessIdentity.read(parent) else { throw ManagerError("Der Starter ist nicht eindeutig feststellbar.") }
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(parent, &path, UInt32(path.count)) > 0,
           ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ksh", "/bin/csh", "/bin/tcsh"].contains(String(cString: path)),
           child.e_tdev != UInt32.max, child.pbi_pgid == UInt32(root.pid), getpgid(parent) != root.pid {
            return nil
        }
        return identity
    }
}
