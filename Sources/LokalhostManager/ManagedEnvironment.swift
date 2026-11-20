import Foundation

enum ManagedEnvironment {
    static func parse(_ text: String) throws -> [String: String] {
        var variables: [String: String] = [:]
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let invalid = ManagerError("Invalid environment file at line \(index + 1). Expected NAME=value.")
            guard let separator = line.firstIndex(of: "="), !line.contains("\0") else { throw invalid }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[a-zA-Z_][a-zA-Z_0-9]*$"#, options: .regularExpression) != nil else { throw invalid }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard value.count >= 2, value.last == quote else { throw invalid }
                value = String(value.dropFirst().dropLast())
            }
            variables[key] = value
        }
        return variables
    }
}
