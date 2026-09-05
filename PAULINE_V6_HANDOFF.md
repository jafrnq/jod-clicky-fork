# Pauline V6 Handoff

## Current state

- **Repository:** `jafrnq/jod-clicky-fork`
- **Working branch:** `test`
- **Remote branch:** `origin/test`
- **Latest commit:** `8c53438 feat: start Pauline speech with the first stream fragment`
- **Main/V5:** untouched. Do not merge V6 into `main` unless the owner explicitly requests it.
- **Xcode project:** `leanring-buddy.xcodeproj` (the `leanring` spelling is intentional; do not rename it).
- **Build/run:** open the project in Xcode, select the `leanring-buddy` scheme, then use Cmd+R. Do **not** run `xcodebuild` from Terminal; it invalidates macOS privacy permissions.

## Product decisions that are locked in

1. This is **Pauline V6**, not V7 or another separate product line.
2. The built application is named **Pauline V6.app** and has bundle identifier `com.yourcompany.leanring-buddy.v6`. It has a separate app identity so it can coexist with the user’s current Pauline V5 installation.
3. ChatGPT/Codex and Claude remain manually selected using the existing backend switch. There is **no automatic provider fallback**.
4. **Gemini integration was explicitly removed from scope.** Do not add Gemini models, Google authentication, or automatic Gemini fallback unless the owner changes this decision.
5. Faster spoken responses are in scope and have been implemented. Preserve the user’s selected voice.

## What has been implemented

### Pauline V6 identity and isolation

- The Xcode product, display name, marketing version, bundle identifier, permissions copy, and release-script app/DMG naming all use Pauline V6.
- V6 stores its Codex configuration and ChatGPT sign-in in its own app-support location:
  `~/Library/Application Support/Pauline V6/CodexHome`.
- This keeps V6 sign-in/sign-out separate from Pauline V5’s Codex state. The V6 code does not create a symlink to V5 credentials or mutate V5’s Codex home.

Relevant files:

- `leanring-buddy.xcodeproj/project.pbxproj`
- `leanring-buddy/Info.plist`
- `scripts/release.sh`
- `leanring-buddy/CodexHomeManager.swift`
- `leanring-buddy/ClickyCodexConfigTemplate.swift`

### ChatGPT/Codex provider

V6 uses the supported local `codex app-server` JSON-RPC route with the user’s ChatGPT subscription; it does not require an API key in the app.

- Locates the local `codex` executable and starts `codex app-server --listen stdio://`.
- Performs the required `initialize` request followed by `initialized` notification.
- Reads ChatGPT account status and plan, starts browser sign-in, and supports sign-out.
- Loads the available model catalog dynamically from `model/list` and shows model/reasoning choices in the panel.
- Sends conversation threads, streamed text, and screenshots through `thread/start` and `turn/start`.
- Supports cancellation, turn completion, timeout, stderr capture, and subprocess termination errors.
- Uses the established manual **Claude / Codex** selector. Claude behavior remains available.

Relevant files:

- `leanring-buddy/AgentBackend.swift`
- `leanring-buddy/AgentModelCatalog.swift`
- `leanring-buddy/CodexRuntimeLocator.swift`
- `leanring-buddy/CodexProcessManager.swift`
- `leanring-buddy/CodexAgentSDKAPI.swift`
- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/CompanionPanelView.swift`

### Codex issues fixed during V6 work

The first V6 Codex run showed “Connect ChatGPT” despite successful authentication, followed by a generic failure reply. These protocol issues are fixed:

- `model/list` parses current `result.data` rows, with legacy `items` compatibility.
- `thread/start` and `turn/start` parse nested `thread.id` and `turn.id`, with compatibility fallbacks.
- The initial persisted model is not sent until the dynamic catalog confirms it; otherwise app-server selects its account default.
- Generic Codex request errors no longer trigger the misleading “all out of credits” voice response. Only actual quota/rate-limit text does.
- The model area communicates loading/failure and exposes retry instead of always saying “Connect ChatGPT.”
- Optional-return types in the model decoder are explicit, fixing the Xcode compile error: `'nil' is not compatible with closure result type`.
- The installed runtime (`codex-cli 0.152.0`) rejects camel-case thread sandbox strings. V6 now uses its runtime-compatible thread values: `workspace-write` and `danger-full-access`.

Direct local verification against the signed-in ChatGPT Plus account succeeded for initialization, account read, model list, thread creation, streamed response, and turn completion. The verified response was `Pauline test passed.`

### Voice, selected-voice handling, and faster first speech

- Voice selection supports Edge neural voices and Apple voices without passing an Edge identifier to Apple Speech.
- Speech is queued sentence-by-sentence so spoken order is preserved while model text streams into the overlay.
- V6 now schedules the **first spoken fragment once, 180 ms after text first streams**. Previously the idle timer was cancelled and restarted for each incoming text token, which could delay first speech by 1–2 seconds until punctuation arrived.
- Later fragments retain the existing sentence/idle-flush behavior. The selected Edge or Apple voice is retained; this change does not substitute another voice to make the first word faster.

Relevant files:

- `leanring-buddy/CompanionManager.swift`
- `leanring-buddy/EdgeTTSClient.swift`
- `leanring-buddy/AppleTTSClient.swift`
- `leanring-buddy/CompanionResponseOverlay.swift`

### Other Pauline foundation already present on `test`

The initial Pauline foundation commit also includes the following app behavior that should be preserved:

- Menu-bar companion panel and cursor appearance controls.
- Push-to-talk, microphone enumeration/selection, and global shortcut handling.
- Streaming transcription improvements and device-change recovery.
- Focused-window/region screen capture and multi-monitor pointing support.
- Agent-mode command approval behavior.
- Cursor and overlay visual updates.

## Commit history on `test`

| Commit | Summary |
| --- | --- |
| `3d326c7` | Pauline integration foundation: Codex bridge, UI/panel, microphone/voice/capture/cursor groundwork. This was committed and pushed before the V6-specific work. |
| `e4b6afa` | Prepared V6: distinct Pauline V6 app identity, bundle, isolated Codex home, V6 UI/configuration. |
| `9fdf263` | Aligned Codex app-server protocol and improved status/error UI. |
| `1aba87d` | Fixed the model decoder’s Swift optional closure typing. |
| `38bcbfa` | Fixed `thread/start` sandbox values for the installed Codex runtime. |
| `8c53438` | Starts first speech from a streaming fragment instead of repeatedly postponing it. |

## Tests and verification performed

- Parsed changed Swift source with `swiftc -parse`.
- Ran `git diff --check` before commits.
- Updated the Graphify code graph after each source change, as required by `AGENTS.md`.
- Added focused Swift Testing coverage for:
  - current ChatGPT account status decoding;
  - current model-list decoding;
  - nested thread/turn identifier decoding;
  - runtime-compatible Codex thread sandbox values;
  - selected Edge voice identifiers not being passed to Apple Speech.
- Performed a live, authenticated local app-server diagnostic using the V6 Codex home. It completed a real streamed turn successfully.

Terminal `xcodebuild` was intentionally not run because this repository’s `AGENTS.md` warns it invalidates TCC/privacy permissions. Full app acceptance testing should be done from Xcode with Cmd+R.

## Known caveats / next-agent notes

1. A live V6 Codex turn was verified after the sandbox correction. The owner should still run Cmd+R and listen to a few real responses to judge the new first-speech timing with their chosen voice/network.
2. The local Codex runtime may report warnings for optional MCP servers inherited from the user’s wider Codex configuration (for example, stale OAuth or unavailable local MCP endpoints). During the diagnostic, those warnings did **not** prevent thread creation or a successful streamed response. Do not make optional MCP servers required just to suppress warnings.
3. The current default persisted model may be `gpt-5.4-mini`, which the dynamic catalog marks as transitioning to a newer model. V6 intentionally supports the catalog and lets the user select an available model; do not hard-code a speculative replacement without owner approval.
4. Do not delete or add the existing untracked scratch/tool artifacts in the repository root (`.agents/`, `.hermes/`, `graphify-out/`, patch scripts, Xcode user data, etc.) unless the owner explicitly asks. They predate or are outside the committed V6 source changes.
5. Do not rename the `leanring-buddy` project/scheme/directory typo. It is a documented legacy name.

## Safe next steps

1. Pull/use `test`, not `main`.
2. Open `leanring-buddy.xcodeproj` in Xcode and run Pauline V6.
3. Validate the manual Claude/Codex switch, ChatGPT model picker, selected voice, and first-response speech latency.
4. Keep Gemini and automatic fallback out of scope unless the owner explicitly reopens them.
