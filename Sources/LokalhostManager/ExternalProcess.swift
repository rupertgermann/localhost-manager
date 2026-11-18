import Darwin
import Foundation

enum ExternalProcess {
    static func stop(_ listener: LocalListener) async throws {
        if let error = listener.controlError { throw ManagerError(error) }
        guard let identity = listener.identity, let executable = listener.executable else {
            throw ManagerError("Keine Berechtigung oder keine bestätigte Identität für diesen Prozess.")
        }
        let fresh = try await ListenerInventory.currentListeners()
        guard let current = fresh.first(where: { $0.identity == identity }),
              current.controlError == nil, current.executable == executable,
              !listener.bindings.isEmpty, Set(current.bindings) == Set(listener.bindings) else {
            throw ManagerError("Prozess oder Bindungen haben sich geändert. Bitte den aktuellen Dienst auswählen.")
        }
        try terminate(identity, executable: executable)

        let deadline = ContinuousClock.now + .seconds(4)
        var quietSince: ContinuousClock.Instant?
        repeat {
            try await Task.sleep(for: .milliseconds(150))
            let listeners = try await ListenerInventory.currentListeners()
            let owners = listeners.filter { candidate in
                candidate.bindings.contains { binding in listener.bindings.contains(where: binding.overlaps) }
            }
            if let other = owners.first(where: { $0.identity != identity }) {
                throw ManagerError("Port weiterhin belegt durch \(other.name) (PID \(other.pid)).")
            }
            if owners.isEmpty && ProcessIdentity.read(identity.pid) != identity {
                if let quietSince, ContinuousClock.now - quietSince >= .milliseconds(650) { return }
                if quietSince == nil { quietSince = .now }
            } else { quietSince = nil }
        } while ContinuousClock.now < deadline
        throw ManagerError("Beendigung nicht bestätigt. Der Prozess läuft noch oder der Port ist weiterhin belegt.")
    }

    private static func terminate(_ identity: ProcessIdentity, executable: String) throws {
        var task: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, identity.pid, &task) == KERN_SUCCESS else {
            throw ManagerError("Keine Berechtigung, die Prozessidentität für das Stoppen zu bestätigen.")
        }
        defer { mach_port_deallocate(mach_task_self_, task) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: token) / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutableBytes(of: &token) { bytes in
            task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), bytes.bindMemory(to: integer_t.self).baseAddress, &count)
        }
        guard result == KERN_SUCCESS, ProcessIdentity.read(identity.pid) == identity,
              ProcessIdentity.executable(of: identity.pid) == executable else {
            throw ManagerError("Die Prozessidentität hat sich geändert oder lässt sich nicht bestätigen.")
        }
        // Das Audit-Token bindet SIGTERM auch bei sofortiger PID-Wiederverwendung an diesen Prozess.
        guard proc_signal_with_audittoken(&token, SIGTERM) == 0 else {
            throw ManagerError("Stoppen fehlgeschlagen: \(String(cString: strerror(errno))).")
        }
    }
}
