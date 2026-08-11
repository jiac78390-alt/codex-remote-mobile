import Foundation

private enum StoreRegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw StoreRegressionFailure.failed(message) }
}

@main
private enum DesktopGlobalStateStoreRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexremote-global-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".codex-global-state.json")
        try write([
            "unrelated": ["preserved": true],
            "pinned-thread-ids": ["thread-old"],
            "projectless-thread-ids": ["thread-loose"],
            "thread-project-assignments": [
                "thread-move": ["projectKind": "local", "projectId": "project-a"]
            ],
            "sidebar-project-thread-orders": [
                "project-a": ["threadIds": ["thread-move", "thread-a"]],
                "project-b": ["threadIds": ["thread-b"]]
            ]
        ], to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateURL.path)

        let store = DesktopGlobalStateStore(stateURL: stateURL)
        try awaitMutation { store.setThreadPinned("thread-new", pinned: true, completion: $0) }
        var state = try read(stateURL)
        try require((state["pinned-thread-ids"] as? [String])?.first == "thread-new", "new pin was not first")
        try require((state["unrelated"] as? [String: Bool])?["preserved"] == true, "unrelated state was lost")
        let savedPermissions = try permissions(stateURL)
        try require(savedPermissions == 0o644, "atomic write changed the original file mode")

        let concurrentPins = (0..<12).map { "thread-concurrent-\($0)" }
        let group = DispatchGroup()
        let resultLock = NSLock()
        var concurrentErrors: [Error] = []
        for threadID in concurrentPins {
            group.enter()
            store.setThreadPinned(threadID, pinned: true) { result in
                if case .failure(let error) = result {
                    resultLock.lock()
                    concurrentErrors.append(error)
                    resultLock.unlock()
                }
                group.leave()
            }
        }
        try require(group.wait(timeout: .now() + 5) == .success, "concurrent pin updates timed out")
        try require(concurrentErrors.isEmpty, "a concurrent pin update failed")
        state = try read(stateURL)
        let pinnedAfterConcurrency = Set(state["pinned-thread-ids"] as? [String] ?? [])
        try require(concurrentPins.allSatisfy(pinnedAfterConcurrency.contains), "a concurrent pin update was lost")

        try awaitMutation {
            store.assignThread(
                "thread-move",
                projectID: "project-b",
                cwd: "/tmp/project-b",
                completion: $0
            )
        }
        state = try read(stateURL)
        let assignments = state["thread-project-assignments"] as? [String: [String: Any]]
        try require(assignments?["thread-move"]?["projectId"] as? String == "project-b", "assignment did not move")
        let orders = state["sidebar-project-thread-orders"] as? [String: [String: Any]]
        try require((orders?["project-a"]?["threadIds"] as? [String])?.contains("thread-move") == false, "old order retained thread")
        try require((orders?["project-b"]?["threadIds"] as? [String])?.first == "thread-move", "new order did not lead")

        try awaitMutation {
            store.assignThread("thread-move", projectID: nil, cwd: "/tmp/project-b", completion: $0)
        }
        state = try read(stateURL)
        try require(
            (state["thread-project-assignments"] as? [String: Any])?["thread-move"] == nil,
            "projectless assignment was retained"
        )
        try require((state["projectless-thread-ids"] as? [String])?.first == "thread-move", "projectless order missing")

        try awaitMutation { store.removeThreadMetadata("thread-move", completion: $0) }
        state = try read(stateURL)
        try require((state["projectless-thread-ids"] as? [String])?.contains("thread-move") == false, "deleted metadata remained projectless")
        try require((state["pinned-thread-ids"] as? [String])?.contains("thread-move") == false, "deleted metadata remained pinned")
        let finalOrders = state["sidebar-project-thread-orders"] as? [String: [String: Any]] ?? [:]
        try require(
            finalOrders.values.allSatisfy { (($0["threadIds"] as? [String]) ?? []).contains("thread-move") == false },
            "deleted metadata remained in a project order"
        )

        print("PASS desktop global state: atomic pin, assign, projectless, metadata removal")
    }

    private static func awaitMutation(
        _ operation: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        operation {
            result = $0
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            throw StoreRegressionFailure.failed("state mutation timed out")
        }
        try result?.get()
    }

    private static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreRegressionFailure.failed("state file is not a JSON object")
        }
        return object
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw StoreRegressionFailure.failed("state file permissions are missing")
        }
        return permissions.intValue
    }
}
