<p align="center">
  <img src="Assets/Brand/DWS-Assistant.svg" width="112" alt="DWS Assistant icon">
</p>

<h1 align="center">DWS Assistant</h1>

<p align="center">Manage your DWS Assistant on macOS.</p>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

<p align="center"><a href="#installation">Build and install</a> · <a href="#usage">Usage</a> · <a href="https://github.com/StarRain/DWS-Assistant/issues">Report an issue</a></p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-v1.0.1-456bf4">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-10172f">
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-456bf4">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-456bf4"></a>
</p>

DWS Assistant is a native macOS app that connects to DingTalk through [DingTalk Workspace CLI (DWS)](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli). It uses locally installed AI engines to process messages and reply in the original chat using your account. The app includes a main window, a menu bar panel, and a standalone quick panel.

> This version supports one signed-in DingTalk account, with group and direct chats. You turn on the assistant manually after signing in.

## Preview

![DWS Assistant in English](docs/assets/assistant-dark-en.svg)

Captured in preview mode. Account details, chats and statistics are sample data.

## Features

### Chats and listening

- Search by group or contact name, select a result, then configure and add it. No manual ID entry is needed.
- Control listening and automatic replies separately for each group or contact.
- Groups default to **Only when you mention yourself**. You can also reply when anyone mentions you, or to incoming messages.
- Filters assistant replies and deduplicates events. Stopping the assistant or disabling listening cancels the corresponding tasks.
- Detects authorization changes. Signing out through the app or DWS CLI stops the assistant and returns to the sign-in page.

### AI replies and interactive cards

- Supports **Codex, Claude Code, Qoder, QoderWork, OpenCode, WorkBuddy, CodeBuddy, Gemini, Pi**, and **custom Agents**. Built-in channels use existing installations and sign-in state; custom Agents can use local models.
- Set the engine, model, reasoning level and execution permissions for each chat. Available options can be read from the engine.
- Reply with plain text, Markdown or AI cards. Cards show processing status first, then update the same card with the result.
- Interactive cards support confirmation, cancellation, single and multiple choices, and text input. The default response timeout is **60 seconds** and can be changed.
- Codex cards can show actual command and tool progress. Reactions on the original message can indicate processing, completion or failure.
- Supports images in the current message and quoted messages from the same chat, subject to the selected model's capabilities.

### Rules and context

- Define reply guidelines or task steps for each chat. There is no limit on the number of rules; each rule supports up to 2,000 characters.
- Add and edit rules in a separate dialog. Enable, edit or delete them from the list, or clone selected rules from another chat as independent copies.
- Each DingTalk group or direct chat maps to its own Codex chat in `~/.dws-assistant/codex/`. Model and reasoning changes apply on the next turn of the same chat.
- Open **History** on a Codex chat row to read messages, replies and execution records, refresh them or load earlier records. Viewing history does not start an AI task.
- Customize the Codex chat name, or leave it blank to use the group or contact name.
- Authorized directories are empty by default. You can add multiple directories and configure execution permissions separately.

### macOS experience

- English and Simplified Chinese interfaces, defaulting to **Simplified Chinese**. Switch instantly in **Settings → Language**, or use the language selector on the sign-in page.
- Light, dark and system appearance, with consistent vector icons.
- Control the assistant and view statistics and recent activity from the menu bar or quick panel.
- Closing the main window hides the Dock icon while keeping the menu bar and running services available.
- Quitting stops listeners and active tasks, then exits after cleanup. If stopping is incomplete, the app stays open so you can retry.
- Optional launch at macOS login. Launching the app does not automatically start listening.

Interface language does not change chat names, custom rules, engine settings, AI reply language or the original logs stored on disk. Raw output from DWS and AI engines remains in its original language.

## How it works

```text
DingTalk group / direct chat
  → Official DWS event subscription
  → Chat settings, trigger checks and reply deduplication
  → Local AI engine (built-in channel / custom Agent)
  → DWS replies to the original chat using the current account
```

DWS handles authorization, messages and reactions. DWS Assistant manages chat settings and task state, reusing the local AI adapters from a pinned DWS version. Gemini retains its existing local CLI adapter. For `custom`, enter a headless launch command in chat settings; it is passed unchanged to the official DWS `agent-cmd` adapter, which appends the message as the last argument and uses stdout as the reply. Model, permissions and memory for custom Agents belong in the command or Agent configuration. Complex launch logic should be placed in a wrapper script, following the pinned DWS command parsing behavior. The app does not move your installed tools or change their global configuration.

The `dsh` channel uses a separate digital-employee binding and host lifecycle. It is not available in this personal-account app.

## Installation

### Download the DMG

Download **DWS-Assistant-1.0.1-arm64.dmg** from [GitHub Releases](https://github.com/StarRain/DWS-Assistant/releases/latest). This package requires **Apple Silicon (M-series chips) and macOS 14 or later**.

Open the DMG, drag **DWS Assistant.app** to **Applications**, then launch it from Applications. DWS CLI and an AI engine must still be installed and signed in to separately.

This release is ad hoc signed and has not been notarized by Apple. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway** for this download. The release also includes a `.sha256` checksum file. Download both files to the same directory and verify them with:

```sh
shasum -a 256 -c DWS-Assistant-1.0.1-arm64.dmg.sha256
```

### Requirements

- macOS 14 or later. The current build has been verified on Apple Silicon.
- [DWS CLI](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli#installation) installed.
- An installed and signed-in built-in AI engine, or a custom Agent that runs once per message and writes its reply to stdout.
- Building from source requires Swift 6, Xcode command line tools, Go 1.26.7 or later, and Python 3.

### Build from source

You can also build from source:

```sh
git clone https://github.com/StarRain/DWS-Assistant.git
cd DWS-Assistant
bash scripts/build-app.sh
```

The first build downloads and verifies the pinned DWS source and dependencies. Go is discovered through `PATH` or `.build/toolchain/go/bin/go`; set `DWS_ASSISTANT_GO` to use a specific executable.

The output is `dist/DWS Assistant.app`. Copy it to Applications and open it. The build script bundles the AI adapter helper, icons, language resources and licenses, then applies an ad hoc signature. The app is currently not notarized by Apple.

Run `bash scripts/build-dmg.sh` to build the app and create a DMG for the current architecture, along with a SHA-256 checksum file, in `dist/`. Add `--skip-build` to package an app that has already been built.

## Usage

1. Open the app and check DWS installation on the setup page. Click **Sign in** to complete the official DingTalk authorization flow.
2. Open **Groups** or **Chat**, click **Add group** or **Add chat**, then search and select a chat.
3. Enable listening and automatic replies. Choose a trigger, reply format and AI engine. Add authorized directories when the AI needs to read a project.
4. To define reply style or task steps, open **AI reply settings → Custom rules**. Save the chat settings after editing rules.
5. Turn on **DWS Assistant** at the bottom left. You can close the main window and keep using the menu bar. **Stop assistant and quit** stops the services, waits for cleanup, then exits.

Group reply triggers:

| Option | When it replies |
| --- | --- |
| Only when you mention yourself (default) | The signed-in account manually sends a real self-mention |
| When anyone mentions you | Another person or you mention the signed-in account |
| Reply to incoming messages | A message arrives from someone else, or you manually mention yourself |

Assistant replies never trigger another reply. Existing chats keep their saved trigger. Automatic replies for direct chats are enabled per contact.

| Shortcut | Action |
| --- | --- |
| `⇧⌘D` | Open the quick panel |
| `⌘Q` | Stop the assistant and quit |

Additional implementation and behavior details are available in the [configuration guide (Chinese)](docs/CONFIGURATION.md).

### Codex chats and history

Each group or direct chat has its own Codex context. Changes to the model, reasoning level, authorized directories, execution permissions, rules or chat name apply on the next turn without creating a new chat.

Click **History** in the chat list to view user messages, AI replies and execution records for the currently bound chat, including expandable command details. The panel only reads this app's saved records. It does not start the AI, acquire the chat's writer lock, or display internal instructions or reasoning records.

After switching to dedicated storage, the first reply creates a new Codex chat without adopting or migrating old history. Existing desktop Codex records remain intact. New DingTalk chats do not appear in the recent chats of desktop Codex using its default storage. If this app's native chat record has been deleted, a replacement is created only after Codex confirms the record is missing and before task execution starts; the log reports the lost context.

### Settings and rule priority

Messages pass the app's programmatic checks before the AI is called. The engine then runs with its configured settings and interprets applicable custom rules. **Programmatic controls and actual engine permissions take precedence over custom rules.**

| Layer | Includes | Conflict behavior |
| --- | --- | --- |
| App controls | Listening switch, reply trigger, recipient, reply format, timeouts | Enforced by code; text rules cannot override them |
| Engine configuration and permissions | Model, reasoning level, execution permissions and directory parameters | Applied through engine arguments or APIs; rules cannot elevate actual permissions |
| Custom rules | Applicable reply requirements, information handling, workflows and behavior limits | Take precedence over default text instructions; conflicting rules require clarification |
| Default text instructions | Default language, reply style and task planning | Apply only when consistent with the applicable rules |

For example, if the app is set to **When anyone mentions you**, a rule saying “only reply when I mention myself” does not prevent another person's mention from entering the AI processing flow. Do not rely on a text rule for strict identity filtering. Select **Only when you mention yourself** in the app to filter before calling the AI.

Likewise, a rule saying “run the build script” does not grant write access. Configure the necessary directories and execution permissions in the app, and avoid contradictory rules.

With enabled rules, the assistant is instructed to perform only the processing required by applicable rules and the necessary steps, without adding tasks or substituting its own approach. Global reply constraints remain active; conditional rules apply only when their conditions are met. Rules are not all treated as the same kind of task. Specified steps, tools, parameters, formats, destinations and delivery methods must be preserved. Work delegated to an existing tool or workflow must use its specified entry point, without reconstructing or resending partial results. Missing applicable rules, missing information, conflicting rules or execution failures require clarification rather than skipped steps, silent fallbacks or reruns.

These general constraints accompany enabled rules on each turn. Natural-language rules are still interpreted by the engine, not programmatically verified for every operation. With no enabled rules, the existing behavior is retained. The app does not prescribe business workflows or add content-based script reviews or blocks. The host returns the automatic reply, while rule-defined deliverables remain with the designated workflow. Directory authorization, actual engine permissions and timeouts still apply.

## Data and permissions

- Codex offers Read only, Ask for approval, Auto-review, and Full access. Existing full/relaxed settings retain auto-review and are never upgraded silently. Native approval requests can be handled in either a DingTalk card or the assistant panel; a single decision returns to the waiting engine request without replaying the task. Commands and file changes receive one-time approval; permission grants last only for the current turn. Requests expire within 90 seconds or the remaining task deadline, and stop being valid when the task stops or its configuration changes. Ordinary AI confirmation forms do not grant engine permissions.
- The app is named DWS Assistant, with Bundle ID `com.starrain.dwsassistant`. Upgrades preserve existing settings and chat records.
- App data lives in `~/.dws-assistant`, including configuration, activity logs, delivery records and engine chat mappings. On upgrade, the complete `~/.dws-dashboard` store is moved to the new location. The old path remains as a compatibility symlink; an existing destination is never overwritten. Chat bindings migrate to the `assistant` namespace without creating new chats. New cards use the new protocol, while previously sent cards remain compatible.
- Codex message content, execution records, databases, runtime logs and writer locks live in `~/.dws-assistant/codex/`, separate from authorized project directories and desktop Codex history.
- DWS and AI engines keep their own sign-in state. The app does not migrate their credentials.
- The dedicated Codex directory links to existing configuration, sign-in files, rules, skills and other inputs. It does not copy old chats or share desktop databases or writer locks.
- Authorized directories are empty by default. Adding a directory does not elevate execution permissions. The directory list is not a complete file-reading sandbox; actual access depends on the engine's permissions.
- Ordinary message bodies are not written to activity logs. AI card delivery records include card content and interaction definitions. Native Codex chat records include message and reply content; other AI engines may also retain their own chat history.
- Images are cached temporarily: up to 64 MiB total, 8 MiB per image and 4 images per message, cleared after processing.
- Unconfirmed deliveries are retained for investigation and are not automatically resent. Expired interactive cards cannot execute tasks.

## Development and verification

```sh
# Swift core and application tests
bash scripts/swift.sh test

# Official adapter tests
bash scripts/build-bridge.sh --test

# Build the app
bash scripts/build-app.sh
```

An isolated preview uses sample accounts and chats, without real listeners or AI tasks:

```sh
open -n "dist/DWS Assistant.app" --args --preview --data-dir /tmp/dws-assistant-preview
```

```text
Sources/AssistantCore       Configuration, commands, event routing and persistence
Sources/DWSAssistant        SwiftUI interface, localization and task coordination
Integrations/DWSBridge      Official DWS AI adapter wrapper and tests
Tests                      Swift regression tests
Assets                     Brand and vector UI assets
scripts                    Build, icon generation and license collection
```

Tests use temporary directories and mocked CLIs. They cover routing, reply loop prevention, chat recovery and storage isolation, read-only history, configuration changes, image caching, interactive cards, language switching and cleanup before quitting. Automated tests do not send messages to real DingTalk chats.

## Related projects

- [DingTalk Workspace CLI](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli): the official DingTalk CLI; this project uses its messaging capabilities and local AI adapters.
- [Codex Account Manager](https://github.com/StarRain/Codex-Account-Manager): a native macOS Codex account manager by the same author.

## Contributing

Report bugs or suggestions through [Issues](https://github.com/StarRain/DWS-Assistant/issues), or submit a pull request.

Include your macOS version, DWS and AI engine versions, reproduction steps and redacted logs. Run tests relevant to your change before submitting. Commit titles use `type(scope): summary`, for example `fix(cards): update card state after cancellation`.

## License

Project code is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for copyright and third-party component details.

The original UI icon reference download did not include author or license information. This project's license does not grant additional rights to those third-party assets; verify their license before reusing them.

## About this project

DWS Assistant is an independent community project, not an official DingTalk product. DingTalk, Codex, Claude, Qoder, Gemini and other names and trademarks belong to their respective owners.
