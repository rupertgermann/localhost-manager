import SwiftUI

enum ProcessCategory: String, CaseIterable {
    case docker = "Docker"
    case node = "Node.js"
    case bunDeno = "Bun / Deno"
    case python = "Python"
    case java = "Java"
    case php = "PHP"
    case ruby = "Ruby"
    case dotnet = ".NET"
    case database = "Databases"
    case webServer = "Web servers"
    case other = "Other"

    var color: Color {
        switch self {
        case .docker: .blue
        case .node: .green
        case .bunDeno: .mint
        case .python: .orange
        case .java: .red
        case .php: .purple
        case .ruby: .pink
        case .dotnet: .indigo
        case .database: .teal
        case .webServer: .brown
        case .other: .gray
        }
    }

    var badge: some View {
        Text(rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }

    var rowBackground: some View {
        Rectangle().fill(color.opacity(0.07))
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: 3)
            }
    }

    static func fromProcess(_ name: String?) -> Self? {
        if LocalListener.isDockerForwarder(name) { return .docker }
        guard let name, let command = (name as NSString).lastPathComponent.lowercased().split(separator: " ").first else { return nil }
        switch command {
        case "node", "nodejs", "next-server", "npm", "npx": return .node
        case "bun", "deno": return .bunDeno
        case "python", "uvicorn", "gunicorn": return .python
        case "java", "javaw": return .java
        case "php", "php-fpm", "php-cgi": return .php
        case "ruby", "puma": return .ruby
        case "dotnet": return .dotnet
        case "postgres", "postmaster", "mysqld", "mariadbd", "redis-server", "mongod", "valkey-server": return .database
        case "nginx", "httpd", "apache2", "caddy", "traefik": return .webServer
        case "com.docker.backend": return .docker
        default:
            if command.hasPrefix("python"), command.dropFirst("python".count).first?.isNumber == true { return .python }
            return nil
        }
    }
}

extension ServiceRow {
    var category: ProcessCategory {
        if let listener {
            return ProcessCategory.fromProcess(listener.executable)
                ?? ProcessCategory.fromProcess(listener.name)
                ?? .other
        }
        return ProcessCategory.fromProcess(record?.executable) ?? .other
    }
}
