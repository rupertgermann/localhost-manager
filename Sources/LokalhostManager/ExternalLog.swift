import Darwin
import Foundation

enum FileLog: Equatable {
    case unavailable(String)
    case empty
    case output(String, truncated: Bool)

    static func read(path: String?) -> Self {
        guard let path, !path.isEmpty else {
            return .unavailable("No log file selected. Choose a file under Edit.")
        }
        guard let localPath = LocalVolumes().resolveLocalPath(path) else {
            return .unavailable("Choose a log file on a local filesystem.")
        }
        let fd = open(localPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard fd >= 0 else { return .unavailable("Could not read the log file: \(String(cString: strerror(errno))).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                return .unavailable("The log source is not a regular file.")
            }
            let limit = 64 * 1024
            let offset = max(0, info.st_size - off_t(limit))
            try file.seek(toOffset: UInt64(offset))
            guard let bytes = try file.read(upToCount: limit), !bytes.isEmpty else { return .empty }
            return .output(String(decoding: bytes, as: UTF8.self), truncated: offset > 0)
        } catch {
            return .unavailable("Could not read the log file: \(error.localizedDescription)")
        }
    }
}
