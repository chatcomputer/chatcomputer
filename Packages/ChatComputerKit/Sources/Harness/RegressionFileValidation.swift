import Foundation

/// Extra evidence for copy/index tasks; these checks are also implemented by external.py.
enum RegressionFileValidation {
    static func text(_ data: Data) -> String {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let value = String(data: data, encoding: .utf16) { return value }
        let bytes = data.starts(with: [0xef, 0xbb, 0xbf]) ? data.dropFirst(3) : data[...]
        return String(decoding: bytes, as: UTF8.self)
    }

    static func file(_ url: URL, data: Data, name: String,
                     attachment: URL?, unorderedLines: [String]?) -> [String] {
        var failures: [String] = []
        if let attachment {
            let symbolic = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            if symbolic || (try? Data(contentsOf: attachment)) != data {
                failures.append("\(name) differs from the attached file")
            }
        }
        if let unorderedLines {
            func lines(_ values: [String]) -> [String] {
                values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }.sorted()
            }
            if lines(text(data).components(separatedBy: .newlines)) != lines(unorderedLines) {
                failures.append("\(name) does not list exactly the expected paths")
            }
        }
        return failures
    }

    static func inventory(_ root: URL, expected: [String]) -> [String] {
        // Relative entries avoid /var versus /private/var and shared-folder aliases.
        guard let enumerator = FileManager.default.enumerator(atPath: root.path)
        else { return ["cannot inspect the outbox"] }
        var actual = Set<String>()
        var failures: [String] = []
        for case let relative as String in enumerator {
            let url = root.appendingPathComponent(relative)
            if url.lastPathComponent == ".DS_Store" || url.lastPathComponent.hasPrefix("._") { continue }
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                failures.append("cannot inspect \(url.lastPathComponent)")
                continue
            }
            if info.isRegularFile == true || info.isSymbolicLink == true {
                actual.insert(relative.lowercased())
            }
        }
        let wanted = Set(expected.map { $0.lowercased() })
        if !actual.subtracting(wanted).isEmpty {
            failures.append("unexpected outbox files: " + actual.subtracting(wanted).sorted().joined(separator: ", "))
        }
        if !wanted.subtracting(actual).isEmpty {
            failures.append("missing outbox files: " + wanted.subtracting(actual).sorted().joined(separator: ", "))
        }
        return failures
    }
}
