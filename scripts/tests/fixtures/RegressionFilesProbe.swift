import Foundation

@main
struct RegressionFilesProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-regression-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Text/poem.txt", "Text/letter.txt", "Images/gradient.png", "Data/expenses.csv"]
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("original \(name)".utf8).write(to: url)
        }
        let index = root.appendingPathComponent("index.txt")
        let valid = names.reversed().joined(separator: "\n") + "\n"
        let utf16 = valid.data(using: .utf16)!
        try utf16.write(to: index)
        func require(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: \(label)") }
            print("PASS: \(label)")
        }
        require(RegressionFileValidation.file(index, data: utf16, name: "index.txt", attachment: nil, unorderedLines: names).isEmpty,
                "UTF16 index with arbitrary order")
        let inventory = RegressionFileValidation.inventory(root, expected: names + ["index.txt"])
        if !inventory.isEmpty {
            FileHandle.standardError.write(Data("Inventory errors: \(inventory) root=\(root.path)\n".utf8))
        }
        require(inventory.isEmpty, "exact output inventory")
        let source = root.appendingPathComponent("Text/letter.txt")
        let bytes = try Data(contentsOf: source)
        require(RegressionFileValidation.file(source, data: bytes, name: "letter.txt", attachment: source, unorderedLines: nil).isEmpty,
                "byte-exact copied file")
        require(!RegressionFileValidation.file(source, data: Data("changed".utf8), name: "letter.txt", attachment: source, unorderedLines: nil).isEmpty,
                "changed copy rejected")
        let bad = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        require(!RegressionFileValidation.file(index, data: bad, name: "index.txt", attachment: nil, unorderedLines: names).isEmpty,
                "actual stale-index false pass rejected")
        let duplicate = Data((valid + names[0] + "\n").utf8)
        require(!RegressionFileValidation.file(index, data: duplicate, name: "index.txt", attachment: nil, unorderedLines: names).isEmpty,
                "duplicate index entry rejected")
        let extra = root.appendingPathComponent("planets.html")
        try Data("stale attachment".utf8).write(to: extra)
        require(!RegressionFileValidation.inventory(root, expected: names + ["index.txt"]).isEmpty,
                "stale extra file rejected")
        try FileManager.default.removeItem(at: extra)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        require(RegressionFileValidation.inventory(root, expected: names + ["index.txt"]).isEmpty,
                "Finder metadata ignored")
        try FileManager.default.removeItem(at: source)
        require(!RegressionFileValidation.inventory(root, expected: names + ["index.txt"]).isEmpty,
                "missing copied file rejected")
        print("9 native regression-file checks passed")
    }
}
