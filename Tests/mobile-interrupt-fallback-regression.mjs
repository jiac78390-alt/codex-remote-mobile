import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(
  path.join(root, "CodexRemoteIOS/RemoteClient.swift"),
  "utf8",
);

function requireSource(pattern, message) {
  if (!pattern.test(source)) throw new Error(message);
}

requireSource(
  /private var interruptConfirmationFallbackTask: Task<Void, Never>\?/,
  "the mobile client does not retain a cancellable runtime-confirmation fallback",
);
requireSource(
  /case RemoteMessage\.hello:[\s\S]*?replayOutbox\(\)[\s\S]*?scheduleInterruptConfirmationFallback\(\)/,
  "reconnect does not arm the fallback after the initially ordered replay",
);
requireSource(
  /Task\.sleep\(nanoseconds: 4_000_000_000\)[\s\S]*?ReliableInterruptFallbackPolicy\.messageIDToProbe[\s\S]*?self\.transmit\(command\)[\s\S]*?markAttempted/,
  "the bounded fallback does not safely probe and retain the oldest interrupt",
);
requireSource(
  /func pauseConnectionMonitoring\(\)[\s\S]*?interruptConfirmationFallbackTask\?\.cancel\(\)/,
  "backgrounding does not cancel the pending fallback task",
);
requireSource(
  /private func closeTransport\(\)[\s\S]*?interruptConfirmationFallbackTask\?\.cancel\(\)/,
  "transport shutdown does not cancel the pending fallback task",
);

console.log("PASS mobile interrupt fallback wiring");
