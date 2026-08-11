import Foundation

private enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure.failed(message) }
}

@main
private enum DesktopIPCHistoryRequestRegression {
    static func main() throws {
        let queue = DispatchQueue(label: "desktop-ipc-history-request-regression")
        let coordinator = DesktopIPCRequestCoordinator(queue: queue, requestTimeout: 0.08)

        var successResult: Result<[String: Any], Error>?
        let request = coordinator.prepareRequest(
            clientID: "companion-client",
            method: "thread-follower-load-complete-history",
            version: 1,
            params: ["hostId": "local", "conversationId": "thread-123"],
            completion: { successResult = $0 }
        )
        let requestID = try requireString(request["requestId"], "requestId")
        try require(request["type"] as? String == "request", "request type was not encoded")
        try require(request["sourceClientId"] as? String == "companion-client", "source client was omitted")
        try require((request["version"] as? NSNumber)?.intValue == 1, "protocol version was not 1")
        try require(request["method"] as? String == "thread-follower-load-complete-history", "method mismatch")
        try require((request["timeoutMs"] as? NSNumber)?.intValue == 80, "router timeout was not encoded")
        let params = try requireObject(request["params"], "params")
        try require(params["hostId"] as? String == "local", "hostId mismatch")
        try require(params["conversationId"] as? String == "thread-123", "conversationId mismatch")

        let unrelatedHandled = coordinator.resolve([
            "type": "response",
            "requestId": "another-request",
            "resultType": "success",
            "method": "thread-follower-load-complete-history",
            "result": ["revision": 1]
        ])
        try require(!unrelatedHandled, "an unrelated response consumed the pending request")
        try require(successResult == nil, "an unrelated response fired the completion")

        let successHandled = coordinator.resolve([
            "type": "response",
            "requestId": requestID,
            "resultType": "success",
            "method": "thread-follower-load-complete-history",
            "result": ["revision": 42]
        ])
        try require(successHandled, "the matching response was not handled")
        guard case .success(let result)? = successResult else {
            throw RegressionFailure.failed("the matching response did not succeed")
        }
        try require((result["revision"] as? NSNumber)?.intValue == 42, "the response result was lost")

        var rejection: Result<[String: Any], Error>?
        let rejectedRequest = coordinator.prepareRequest(
            clientID: "companion-client",
            method: "thread-follower-load-complete-history",
            version: 1,
            params: ["hostId": "local", "conversationId": "thread-rejected"],
            completion: { rejection = $0 }
        )
        let rejectedID = try requireString(rejectedRequest["requestId"], "rejected requestId")
        try require(coordinator.resolve([
            "type": "response",
            "requestId": rejectedID,
            "resultType": "error",
            "error": "no-client-found"
        ]), "the error response was not handled")
        guard case .failure(let rejectionError)? = rejection,
              rejectionError.localizedDescription.contains("no-client-found") else {
            throw RegressionFailure.failed("the router rejection was not preserved")
        }

        let timeoutSemaphore = DispatchSemaphore(value: 0)
        var timeoutError: Error?
        _ = coordinator.prepareRequest(
            clientID: "companion-client",
            method: "thread-follower-load-complete-history",
            version: 1,
            params: ["hostId": "local", "conversationId": "thread-timeout"],
            completion: { result in
                if case .failure(let error) = result { timeoutError = error }
                timeoutSemaphore.signal()
            }
        )
        try require(timeoutSemaphore.wait(timeout: .now() + 1) == .success, "timeout completion did not fire")
        try require(timeoutError is DesktopIPCRequestError, "timeout did not use the IPC request error")
        try require(timeoutError?.localizedDescription.contains("timed out") == true, "timeout error was not explicit")

        var disconnected: Result<[String: Any], Error>?
        _ = coordinator.prepareRequest(
            clientID: "companion-client",
            method: "thread-follower-load-complete-history",
            version: 1,
            params: ["hostId": "local", "conversationId": "thread-disconnected"],
            completion: { disconnected = $0 }
        )
        coordinator.failAll(with: .disconnected)
        guard case .failure(let disconnectError)? = disconnected,
              disconnectError.localizedDescription.contains("disconnected") else {
            throw RegressionFailure.failed("disconnect did not fail pending requests")
        }

        print("PASS desktop IPC history request: envelope, correlation, rejection, timeout, disconnect")
    }

    private static func requireString(_ value: Any?, _ label: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw RegressionFailure.failed("missing \(label)")
        }
        return value
    }

    private static func requireObject(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw RegressionFailure.failed("missing \(label)")
        }
        return value
    }
}
