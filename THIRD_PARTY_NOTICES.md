# Third-party notices

DWS Dashboard includes an independently built wrapper around **DingTalk Workspace CLI v1.0.66**, Copyright 2026 Alibaba Group, licensed under the Apache License, Version 2.0.

Pinned source: https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli/tree/f215043e676d6889e1ddce3464828d8b1ec40c31

Source archive SHA-256: `c0427f5389729129470fe882e477711d01a850919e71faafc2b7019b0d76e144`.

The build overlays `Integrations/DWSBridge/dashboard_bridge.go` and `dashboard_progress.go` into the upstream `internal/helpers` package and adds a separate `cmd/dashboard-bridge` entry point. It invokes `newLocalAgentForwarder` and the official Codex app-server, Claude stream-json and Qoder stream-json implementations. Upstream adapter source is unchanged. The wrapper adds validation, isolated state storage, fixed permission options, cancellation, conversation-level settings and a bounded JSON request/result contract. The progress overlay derives portions of its Codex turn handling from DWS and retains the upstream copyright notice. It does not initiate DingTalk subscriptions or send messages.

The installed `dws` CLI continues to own personal authentication, event subscriptions, message delivery and message reactions. The upstream Gemini channel uses API credentials; Gemini CLI is an explicit Dashboard compatibility adapter, not the upstream Gemini API implementation.

The DWS license and dependency notices are included in `Contents/Resources/Licenses` in the application bundle. All upstream source, its `go.mod`, `go.sum`, and third-party notices remain available in `.build/vendor/dws` after building. The build uses the dependency versions and local replacements specified by that source release.

This project is an independent desktop application and is not an official DingTalk product.

## User-supplied interface icon references

The five original SVG references supplied for this project are preserved in
`Assets/Icons/Original`. The interface uses normalized outline SVGs in
`Assets/Icons` and generated SwiftUI vector paths; no PNG icon assets are used.
The original download did not include author or license metadata.

The Apache-2.0 license for DWS Dashboard does not grant additional rights to
this third-party artwork, including the original references, their adapted
SVGs, and the corresponding generated paths in
`Sources/DWSDashboard/DashboardIcon.swift`. Their original author and license
remain unverified; those rights must be established separately before reuse
or redistribution of the artwork.
