import Darwin
import Foundation

public enum ShellLinks {
    /// Only URLs describing an SSH destination are accepted as terminal input.
    public static func command(for url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["t3rm-ssh", "t3rm-review-ssh"].contains(parts.scheme?.lowercased() ?? ""),
              parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let rawHost = parts.host, !rawHost.isEmpty else { return nil }

        let host: String
        if rawHost.contains(":") {
            let address = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
                ? String(rawHost.dropFirst().dropLast()) : rawHost
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return nil }
            host = address
        } else {
            let labels = rawHost.split(separator: ".", omittingEmptySubsequences: false)
            guard rawHost.utf8.count <= 253, labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { asciiAlphanumeric($0) || $0 == 45 }
            }) else { return nil }
            host = rawHost
        }
        var arguments = ["ssh"]
        if let port = parts.port {
            guard (1...65535).contains(port) else { return nil }
            arguments += ["-p", String(port)]
        }
        if let user = parts.user {
            guard !user.isEmpty, user.first != "-", user.utf8.count <= 255,
                  user.utf8.allSatisfy({ asciiAlphanumeric($0) || [45, 46, 95].contains($0) }) else { return nil }
            arguments += ["-l", user]
        }
        return (arguments + ["--", host]).joined(separator: " ")
    }

    private static func asciiAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}
