import Foundation

enum DesktopIPCRequestError: LocalizedError {
    case disconnected
    case timedOut
    case rejected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "Codex desktop IPC disconnected"
        case .timedOut:
            return "Codex desktop IPC request timed out"
        case .rejected(let reason):
            return "Codex desktop IPC rejected the request: \(reason)"
        case .invalidResponse:
            return "Codex desktop IPC returned an invalid response"
        }
    }
}

struct DesktopHistoryRecoveryPolicy {
    let desktopRegistrationGrace: TimeInterval
    let offlineGrace: TimeInterval
    let initialRetryDelay: TimeInterval
    let maximumRetryDelay: TimeInterval

    init(
        desktopRegistrationGrace: TimeInterval = 8,
        offlineGrace: TimeInterval = 2.5,
        initialRetryDelay: TimeInterval = 0.12,
        maximumRetryDelay: TimeInterval = 0.75
    ) {
        self.desktopRegistrationGrace = desktopRegistrationGrace
        self.offlineGrace = offlineGrace
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempt, 8)))
        return min(maximumRetryDelay, initialRetryDelay * pow(1.5, exponent))
    }

    func shouldRetry(
        error: Error,
        elapsed: TimeInterval,
        desktopAppRunning: Bool,
        knownDesktopOwner: Bool
    ) -> Bool {
        guard let ipcError = error as? DesktopIPCRequestError else { return false }
        switch ipcError {
        case .disconnected, .timedOut:
            return desktopAppRunning || elapsed < offlineGrace
        case .rejected(let reason):
            let normalized = reason.lowercased()
            if normalized.contains("no-client-found")
                || normalized.contains("client-not-found") {
                return (knownDesktopOwner && desktopAppRunning)
                    || elapsed < desktopRegistrationGrace
            }
            if normalized.contains("disconnect")
                || normalized.contains("timed out")
                || normalized.contains("timeout")
                || normalized.contains("temporar")
                || normalized.contains("not-ready") {
                return desktopAppRunning || elapsed < offlineGrace
            }
            return false
        case .invalidResponse:
            return false
        }
    }

    static func isActiveWriterConflict(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("already has an active writer")
            || normalized.contains("thread-store conflict")
    }
}

final class DesktopIPCRequestCoordinator {
    typealias Object = [String: Any]
    typealias Completion = (Result<Object, Error>) -> Void

    private struct PendingRequest {
        var method: String
        var timeout: DispatchWorkItem
        var completion: Completion
    }

    private let queue: DispatchQueue
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var pendingRequests: [String: PendingRequest] = [:]

    init(queue: DispatchQueue, requestTimeout: TimeInterval) {
        self.queue = queue
        self.requestTimeout = requestTimeout
    }

    func prepareRequest(
        clientID: String,
        method: String,
        version: Int,
        params: Object,
        completion: @escaping Completion
    ) -> Object {
        let requestID = UUID().uuidString
        let timeout = DispatchWorkItem { [weak self] in
            guard let pending = self?.takePendingRequest(requestID) else { return }
            pending.completion(.failure(DesktopIPCRequestError.timedOut))
        }
        lock.lock()
        pendingRequests[requestID] = PendingRequest(
            method: method,
            timeout: timeout,
            completion: completion
        )
        lock.unlock()
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)

        return [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": max(1, Int((requestTimeout * 1_000).rounded(.up)))
        ]
    }

    @discardableResult
    func resolve(_ response: Object) -> Bool {
        guard response["type"] as? String == "response",
              let requestID = response["requestId"] as? String,
              let pending = takePendingRequest(requestID) else { return false }

        guard response["resultType"] as? String == "success" else {
            let reason = response["error"] as? String ?? "unknown-error"
            pending.completion(.failure(DesktopIPCRequestError.rejected(reason)))
            return true
        }
        guard response["method"] as? String == pending.method,
              let result = response["result"] as? Object else {
            pending.completion(.failure(DesktopIPCRequestError.invalidResponse))
            return true
        }
        pending.completion(.success(result))
        return true
    }

    func failAll(with error: DesktopIPCRequestError) {
        lock.lock()
        let pending = Array(pendingRequests.values)
        pendingRequests.removeAll()
        lock.unlock()
        for request in pending {
            request.timeout.cancel()
            request.completion(.failure(error))
        }
    }

    private func takePendingRequest(_ requestID: String) -> PendingRequest? {
        lock.lock()
        let pending = pendingRequests.removeValue(forKey: requestID)
        lock.unlock()
        pending?.timeout.cancel()
        return pending
    }
}
