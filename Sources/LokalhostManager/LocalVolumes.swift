import Darwin
import Foundation

struct LocalVolumes {
    private let networkMounts: [(id: fsid_t, path: String)]

    init() {
        var table: UnsafeMutablePointer<statfs>?
        // Read the kernel's mount table without requesting updates from the volumes.
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        defer { free(table) }
        let mounts = UnsafeBufferPointer(start: table, count: Int(count)).compactMap { mount -> (id: fsid_t, path: String)? in
            guard mount.f_flags & UInt32(MNT_LOCAL) == 0 else { return nil }
            var name = mount.f_mntonname
            let path = withUnsafeBytes(of: &name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            return (mount.f_fsid, path)
        }
        self.init(networkMounts: mounts)
    }

    init(networkMounts: [(id: fsid_t, path: String)]) {
        self.networkMounts = networkMounts.map { ($0.id, Self.mountLookupPath($0.path)) }
    }

    func isNetworkFileSystem(_ id: fsid_t) -> Bool {
        networkMounts.contains { $0.id.val == id.val }
    }

    func isNetworkPath(_ path: String) -> Bool {
        let path = Self.mountLookupPath(path)
        return networkMounts.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    func resolveLocalPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return path }
        guard !isNetworkPath(path) else { return nil }
        // Check symlink targets before passing the path to realpath or opening a file.
        var pending = Array(path.split(separator: "/").reversed())
        var resolved: [Substring] = []
        var target = [CChar](repeating: 0, count: Int(PATH_MAX))
        var links = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." { _ = resolved.popLast(); continue }
            resolved.append(component)
            let next = "/" + resolved.joined(separator: "/")
            guard !isNetworkPath(next) else { return nil }
            let length = readlink(next, &target, target.count)
            if length < 0 {
                if errno == EINVAL { continue }
                // A local path can be configured before its file or folder exists.
                return errno == ENOENT || errno == ENOTDIR ? path : nil
            }
            guard length < target.count && links < MAXSYMLINKS else { return nil }
            links += 1
            let link = target.withUnsafeBytes { String(decoding: $0.prefix(length), as: UTF8.self) }
            _ = resolved.popLast()
            if link.hasPrefix("/") { resolved.removeAll() }
            pending.append(contentsOf: link.split(separator: "/").reversed())
        }
        guard let buffer = realpath(path, nil) else {
            return errno == ENOENT || errno == ENOTDIR ? path : nil
        }
        defer { free(buffer) }
        let canonical = String(cString: buffer)
        return isNetworkPath(canonical) ? nil : canonical
    }

    private static func mountLookupPath(_ path: String) -> String {
        let path = path.lowercased()
        let dataVolume = "/system/volumes/data"
        return path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }
}
