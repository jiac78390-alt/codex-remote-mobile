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
private enum DesktopHistoryRecoveryPolicyRegression {
    static func main() throws {
        let policy = DesktopHistoryRecoveryPolicy(
            desktopRegistrationGrace: 8,
            offlineGrace: 2.5,
            initialRetryDelay: 0.12,
            maximumRetryDelay: 0.75
        )

        try require(
            policy.shouldRetry(
                error: DesktopIPCRequestError.disconnected,
                elapsed: 20,
                desktopAppRunning: true,
                knownDesktopOwner: false
            ),
            "a running desktop app must not fall through to a second writer"
        )
        try require(
            policy.shouldRetry(
                error: DesktopIPCRequestError.rejected("no-client-found"),
                elapsed: 5,
                desktopAppRunning: true,
                knownDesktopOwner: false
            ),
            "initial follower registration was not given a grace period"
        )
        try require(
            policy.shouldRetry(
                error: DesktopIPCRequestError.rejected("no-client-found"),
                elapsed: 30,
                desktopAppRunning: true,
                knownDesktopOwner: true
            ),
            "a known desktop-owned task was allowed to fall through"
        )
        try require(
            !policy.shouldRetry(
                error: DesktopIPCRequestError.disconnected,
                elapsed: 3,
                desktopAppRunning: false,
                knownDesktopOwner: false
            ),
            "an offline desktop blocked the companion fallback forever"
        )
        try require(
            !policy.shouldRetry(
                error: DesktopIPCRequestError.rejected("no-client-found"),
                elapsed: 9,
                desktopAppRunning: true,
                knownDesktopOwner: false
            ),
            "a confirmed unowned task never reached the companion fallback"
        )
        try require(
            !policy.shouldRetry(
                error: DesktopIPCRequestError.invalidResponse,
                elapsed: 0,
                desktopAppRunning: true,
                knownDesktopOwner: false
            ),
            "a malformed IPC response was treated as transient"
        )
        try require(
            DesktopHistoryRecoveryPolicy.isActiveWriterConflict(
                "thread abc already has an active writer"
            ),
            "the active-writer safety net did not recognize the server error"
        )
        try require(
            policy.retryDelay(afterAttempt: 0) == 0.12,
            "the first retry delay changed unexpectedly"
        )
        try require(
            policy.retryDelay(afterAttempt: 100) == 0.75,
            "retry backoff exceeded its cap"
        )

        print("PASS desktop history recovery: registration grace, owner safety, bounded backoff")
    }
}
