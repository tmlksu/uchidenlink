import Foundation

/// spec/fixtures/ (両 OS 共有のゴールデン) を読む。
enum Fixtures {
    static let specDir: URL = {
        // <repo>/ios/UchidenLinkCore/Tests/UchidenLinkCoreTests/Fixtures.swift から 5 つ上がリポジトリ直下
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("spec")
    }()

    static func url(_ name: String) -> URL {
        specDir.appendingPathComponent("fixtures").appendingPathComponent(name)
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url(name)))
    }
}
