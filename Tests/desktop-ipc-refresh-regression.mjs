import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = fs.readFileSync(
  path.join(root, "Sources/CodexRemoteMac/main.swift"),
  "utf8",
);
const project = fs.readFileSync(
  path.join(root, "CodexRemoteMac.xcodeproj/project.pbxproj"),
  "utf8",
);

function requireSource(pattern, message) {
  if (!pattern.test(source)) throw new Error(message);
}

requireSource(
  /func loadCompleteHistory\([\s\S]*?method: "thread-follower-load-complete-history"[\s\S]*?version: 1[\s\S]*?"hostId": "local"[\s\S]*?"conversationId": threadID/,
  "desktop IPC complete-history request is not encoded as protocol version 1",
);
requireSource(
  /case "response":\s*if requestCoordinator\.resolve\(object\) \{ return \}/,
  "desktop IPC responses are not correlated before initialize handling",
);
requireSource(
  /private func resetConnection\(\)[\s\S]*?requestCoordinator\.failAll\(with: \.disconnected\)/,
  "desktop IPC disconnect does not fail pending requests",
);
requireSource(
  /desktopStreamThreadIDs\.contains\(threadId\), !isCompanionTurn, !forceSnapshot/,
  "a desktop stream marker still suppresses an explicitly forced authoritative snapshot",
);

const refresh = source.indexOf("private func refreshActiveThread(_ threadId: String)");
const ipcCall = source.indexOf("desktopIPC.loadCompleteHistory(threadID: threadId)", refresh);
const inspectorFallback = source.indexOf(
  "desktopHost.refreshActiveThreadViaInspector(threadID: threadId)",
  refresh,
);
if (refresh < 0 || ipcCall < refresh || inspectorFallback < ipcCall) {
  throw new Error("active desktop refresh does not prefer IPC before inspector fallback");
}

const inspectorEntry = source.indexOf("private func executeInMainProcessOnce");
const ownerLookup = source.indexOf("let initialOwners = try inspectorListenerProcessIDs()", inspectorEntry);
const signal = source.indexOf("Darwin.kill(processID, SIGUSR1)", inspectorEntry);
if (inspectorEntry < 0 || ownerLookup < inspectorEntry || signal < ownerLookup) {
  throw new Error("inspector ownership is not checked before SIGUSR1");
}
requireSource(
  /inspectorTarget\(expectedProcessID: pid_t\)[\s\S]*?owners == Set\(\[expectedProcessID\]\)/,
  "inspector target lookup is not restricted to the selected Codex PID",
);
requireSource(
  /application\.bundleIdentifier == "com\.openai\.codex"[\s\S]*?application\.bundleURL[\s\S]*?application\.executableURL/,
  "inspector fallback does not validate the actual running Codex bundle",
);
const hostBridgeSource = source.slice(
  source.indexOf("final class CodexDesktopHostBridge"),
  source.indexOf("final class CodexDesktopIPC"),
);
if (hostBridgeSource.includes("/Applications/Codex.app")) {
  throw new Error("inspector fallback still assumes /Applications/Codex.app");
}
if (!project.includes("DesktopIPCRequestCoordinator.swift in Sources")) {
  throw new Error("Mac target does not compile DesktopIPCRequestCoordinator.swift");
}
if (!project.includes("DesktopGlobalStateStore.swift in Sources")) {
  throw new Error("Mac target does not compile DesktopGlobalStateStore.swift");
}
for (const forbidden of [
  "desktopHost.setThreadPinned",
  "desktopHost.assignThread",
  "desktopHost.removeThreadMetadata",
]) {
  if (source.includes(forbidden)) {
    throw new Error(`${forbidden} still routes common state changes through inspector`);
  }
}
requireSource(
  /desktopState\.setThreadPinned\(threadId, pinned: pinned\)[\s\S]*?case \.success:[\s\S]*?invalidateDesktop\(\)/,
  "pin updates do not use the structured store followed by invalidation",
);
requireSource(
  /desktopState\.removeThreadMetadata\(threadId\)[\s\S]*?else \{\s*self\.invalidateDesktop\(\)/,
  "metadata removal does not use the structured store followed by invalidation",
);
requireSource(
  /desktopState\.assignThread\([\s\S]*?syncResult[\s\S]*?self\.invalidateDesktop\(\)/,
  "project assignment does not use the structured store followed by invalidation",
);

console.log("PASS desktop IPC refresh: IPC-first, structured state, invalidation, PID-owned fallback");
