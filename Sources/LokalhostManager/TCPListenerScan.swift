import Darwin
import Foundation

enum TCPListenerScan {
    static func inventory() throws -> ListenerInventory {
        let pids = try entries(of: pid_t(0)) { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0, $1) }
        guard !pids.isEmpty else { throw ManagerError("Could not read the process list.") }
        var inventory = ListenerInventory(listeners: [], warning: nil)
        for pid in pids where pid > 0 {
            let identity = ProcessIdentity.read(pid)
            do {
                let bindings = try bindings(for: pid)
                guard !bindings.isEmpty else { continue }
                let executable = ProcessIdentity.executable(of: pid)
                var command = [CChar](repeating: 0, count: 256)
                let name = proc_name(pid, &command, UInt32(command.count)) > 0 ? String(cString: command) : "Process \(pid)"
                guard ProcessIdentity.read(pid) == identity else { continue }
                inventory.listeners.append(LocalListener(pid: pid, name: name, identity: identity, executable: executable, bindings: bindings))
            } catch {
                inventory.visibility = .partial
                if inventory.warning == nil {
                    inventory.warning = "Could not inspect TCP listeners for PID \(pid). \(error.localizedDescription)"
                }
            }
        }
        return inventory
    }

    private static func bindings(for pid: pid_t) throws -> [HostBinding] {
        let descriptors = try entries(of: proc_fdinfo()) { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0, $1) }
        let filePorts = try entries(of: proc_fileportinfo()) { proc_pidinfo(pid, PROC_PIDLISTFILEPORTS, 0, $0, $1) }
        var result: [HostBinding] = []
        func addSocket(_ read: (inout socket_fdinfo, Int32) -> Int32) throws {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            errno = 0
            let bytes = read(&socket, size)
            if bytes == 0 && [EBADF, EINVAL, ENOTSOCK].contains(errno) { return }
            try checkRead(bytes)
            guard bytes != 0 else { return }
            guard bytes == size else { throw POSIXError(.EIO) }
            if let binding = binding(for: socket.psi), !result.contains(binding) { result.append(binding) }
        }
        for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            try addSocket { proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &$0, $1) }
        }
        for port in filePorts where port.proc_fdtype == PROX_FDTYPE_SOCKET {
            try addSocket { proc_pidfileportinfo(pid, port.proc_fileport, PROC_PIDFILEPORTSOCKETINFO, &$0, $1) }
        }
        return result
    }

    private static func entries<Entry>(of empty: Entry, read: (UnsafeMutableRawPointer?, Int32) -> Int32) throws -> [Entry] {
        errno = 0
        let estimatedBytes = read(nil, 0)
        try checkRead(estimatedBytes)
        guard estimatedBytes > 0 else { return [] }
        let stride = MemoryLayout<Entry>.stride
        var capacity = Int(estimatedBytes) / stride + 32
        for _ in 0..<3 {
            var buffer = Array(repeating: empty, count: capacity)
            errno = 0
            let bytes = buffer.withUnsafeMutableBytes { read($0.baseAddress, Int32($0.count)) }
            try checkRead(bytes)
            guard bytes >= 0 && Int(bytes) % stride == 0 else { throw POSIXError(.EIO) }
            let count = Int(bytes) / stride
            if count < capacity { return Array(buffer.prefix(count)) }
            capacity *= 2
        }
        throw POSIXError(.EAGAIN)
    }

    private static func checkRead(_ bytes: Int32) throws {
        // A process can exit or be private to another user between kernel queries.
        let code = errno
        if bytes <= 0 && ![0, ESRCH, EACCES, EPERM].contains(code) {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private static func binding(for socket: socket_info) -> HostBinding? {
        guard socket.soi_kind == SOCKINFO_TCP, socket.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
        let details = socket.soi_proto.pri_tcp.tcpsi_ini
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: details.insi_lport)))
        guard port != 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let mappedIPv4 = socket.soi_family == AF_INET6 && details.insi_vflag == INI_IPV4
        if socket.soi_family == AF_INET || mappedIPv4 {
            var address = details.insi_laddr.ina_46.i46a_addr4
            if address.s_addr == INADDR_ANY { return HostBinding(family: "IPv4", host: "*", port: port) }
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return HostBinding(family: "IPv4", host: String(cString: buffer), port: port)
        }
        guard socket.soi_family == AF_INET6 else { return nil }
        var address = details.insi_laddr.ina_6
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let host = String(cString: buffer)
        return HostBinding(family: "IPv6", host: host == "::" ? "*" : "[\(host)]", port: port)
    }
}
