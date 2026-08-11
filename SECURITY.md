# Security Policy

## Supported version

Only the latest release receives security fixes. This project is experimental
and has not received an independent security audit.

## Network boundary

Codex Remote exposes an authenticated WebSocket service on the Mac. Use it only
on a trusted local network or through your own Tailscale network. Do not expose
port `8765` directly to the public internet. The pairing key is a remote-control
credential; anyone who obtains it may control Codex within the permissions
available to the Mac companion.

Codex authentication, provider credentials, model requests, tools, and project
files stay on the Mac. The iOS app stores only its pairing key in Keychain.

## Reporting a vulnerability

Please open a private GitHub security advisory for the repository. Do not put
pairing keys, API keys, tokens, private task content, device identifiers, or
personal file paths in a public issue.
