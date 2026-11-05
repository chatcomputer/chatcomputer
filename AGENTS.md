# AGENTS.md

Guidance for coding agents (Claude Code, Codex, and others) working in this repository. Read
[README.md](README.md) for the layout and [docs/STATUS.md](docs/STATUS.md) for what works and what is next.

The repository is public. The current release is 0.9.11, a 1.0 candidate: features are frozen until 1.0, so
prefer fixing, testing and documenting over adding capabilities.

## Workflow

- **Commit straight to `main`** until the first stable release. Don't use feature branches or pull requests.
  Commit or push only when asked.
- Write the user-facing reply in the user's language (currently Chinese). Docs under `docs/` and
  `TODO.md` are in Chinese; code, comments, `README.md` and this file are in English.
- Record verified findings where they belong:
  - probe results go in `docs/ROADMAP.md` §5.1
  - the current state and the plan go in `docs/STATUS.md`
  - task checkboxes go in `TODO.md`
  - regression results go in `scripts/regress/results/` (JSONL, one file per run set)
- Related repositories: the website is `chatcomputer/chatcomputer.github.io` (static; regenerate its
  `results.json` with `scripts/regress/site-results.py`), the Homebrew cask is `chatcomputer/homebrew-tap`
  (`scripts/update-cask.sh`), and organisation-wide issue templates and policies live in `chatcomputer/.github`.

## Build and test

Requires macOS 27 and Xcode 27.

```sh
xcodegen generate                                   # after editing project.yml; never edit the .xcodeproj
swift test --package-path Packages/ChatComputerKit  # unit tests; stay at the repository root
scripts/test-mac.sh                                 # unit tests, Xcode build, host API checks, live scenarios
```

Don't build the Swift package while `cc-harness` is running a VM: the build relinks the binary in place and
code signing kills the running process. Use `xcodebuild` (its own derived data) or wait.

Before claiming a change works, run the layer that exercises it:

| Change touches | Run |
|---|---|
| Portable logic (BridgeProtocol, ChatCore, ModelProxy, Orchestrator) | `swift test` |
| The agent loop or a model client | `scripts/test-mac.sh` with `CC_API_KEY` (runs notes, approval and injection); one scenario: `scripts/harness.sh live-loop --scenario notes` |
| The guest driver (`AgentCore`) | `scripts/harness.sh vm up --update-agent --input-test 3` |
| Agent behaviour, prompts, cost | `scripts/harness.sh vm regress` (built-in agent) and `scripts/regress/external.py` (Claude Code by default; `--agent codex --model MODEL` for Codex CLI), before and after with the same external agent/model; add `--suite long` for multi-step, multi-app work (`tasks-long.json`) |
| The guest agent's version or driver, for regression | `vm regress --rebuild-base --agent <ChatComputerAgent.app>`: the base snapshot keeps the agent it was made with |
| Lifecycle: quit, sleep, snapshots, long runs | `scripts/test-vm-callbacks.sh` (native delegate ownership, no guest boot), `scripts/soak.py`; a release's install path: `scripts/fresh-install.sh` |
| Apps, onboarding, signing | `scripts/release.sh`, then launch `build/release/ChatComputer.app` |

Documentation-only edits need link and command checks. Script edits need the failure-injection tests in
`scripts/tests/`. For a retained, isolated install run, set `CC_DATA_DIR` to a new directory before
`scripts/fresh-install.sh`; existing files, directories and symlinks are refused. Without that switch, the
script temporarily moves the selected data folder and restores it on exit.
Regression checker or fixture changes also need `scripts/test-regression-files.sh` and a `cc-harness`
build. Each external task gets a new input directory containing only its declared attachments; the
product's cumulative `inbox/external` must not define the task's input set. Keep copy, inventory and
index checks consistent between the native and external runners. A changed harness or task contract
starts a separate current/baseline comparison; preserve original scores and raw events.
Parse the entire actual-agent status line with `scripts/regress/guest_readiness.py`.
The phrase "this app brings VERSION" describes the bundled agent, not the running one.
Check the actual version before capturing a benchmark base and after restoring it; a base
that resumes an older agent and then updates is not proof of a base made with the requested agent.
Keep `guestAgentBeforeTask` in each external result. Restore the pre-run backup and observe
guest readiness before deleting that backup; a successful snapshot response alone is insufficient.
Report unavailable hardware, missing keys and skipped scenarios explicitly. Candidate
regression JSONL files should have a companion manifest from `scripts/regress/run-manifest.py`.
Use `--external-agent codex` in that manifest when testing Codex. Keep its raw events with
`external.py --trace-dir PATH` and set `CC_DATA_DIR` to an isolated test VM. Switching external agents starts a separate comparison; it does not
replace the built-in DeepSeek/Anthropic checks or turn an unavailable historical model run into a pass.
Claude Code is a historical benchmark client, not a product dependency. If its session is unavailable,
use an already available external client and record a separate comparison; do not make its login a
prerequisite for unrelated implementation or functional checks.
Once a trace is hashed into a manifest, treat it as sealed. Give later probes or recovery phases new
filenames; appending to the old trace invalidates the manifest's evidence hashes.

## Rules that are easy to break

1. **XcodeGen owns `Info.plist` and `.entitlements`.** Change properties, the version and entitlements in
   `project.yml`, never in the generated files: `xcodegen generate` overwrites them.
   The host app needs `com.apple.security.virtualization`.
2. **The model is never trusted with policy.** Task phase, the input lease, budgets and output
   verification are enforced in `AgentRunner` and in the guest, not by prompting. Completion requires the
   files listed in `report_result` to exist in the outbox.
3. **Model history is append-only.** Assistant content goes back unchanged, including thinking blocks and
   vendor fields such as `reasoning_content` and Gemini's `extra_content`. Don't rewrite earlier turns for
   Claude. Screenshot trimming applies only to non-Claude endpoints.
4. **Secrets stay on the host, in 0600 files** (`HostSecretStore`): the guest password and pairing token in
   the VM bundle's `secrets.json`, API keys in `credentials.json` in the data folder.
   Never log them, print them, put them in a URL, or commit them. Don't go back to the login Keychain: its
   items are bound to the build that wrote them, so every other build prompts. For a sandboxed release, use the data-protection keychain, which needs a
   provisioning profile (without one, a Developer ID build gets -34018 on every call).
5. **The guest agent's signature matters.** Privacy grants in the guest belong to its signing identity.
   Release builds must use the same Developer ID. Replace the agent bundle; never overwrite it in place,
   or code signing kills the running binary.
6. **Guest input must look like hardware.** Shortcuts press and release modifier keys with device flag
   bits. Text is typed as real key presses where the US layout has the character. Every key event keeps the
   bits a real keyboard sets (`NativeDriver.preservedFlagBits`, including NX_NONCOALESCED): without them,
   out-of-process panels such as the save dialog and Spotlight drop typing after any Cmd or Ctrl shortcut.
7. **The guest agent updates itself from the app.** On connect the app compares the agent's version
   ("0.9.0 (24)", with the build number) to the one it bundles and, when the guest is idle, replaces it through
   the bootstrap share. Snapshots keep the agent they were taken with, so restoring an old one updates it again.
   Bump `CURRENT_PROJECT_VERSION` for every build you put in a guest.
8. **A shared folder caches names in the guest.** A file or folder deleted and recreated on the host under the
   same name reads as stale or missing in a running guest. Give new content a new name (`AgentStaging` stages
   each agent update in its own folder) or delete-then-create each file; never rename over an existing one.
9. **The guest's clock lags after a snapshot restore.** Files it writes carry that time; compare files by
   fingerprint, not modification time (`SaveDialog.fingerprints`).
10. **The main window is AppKit; the rest is SwiftUI.** `MainWindowController` owns the window, its toolbar and
    its aspect-ratio resizing; the chat transcript is a ListViewKit `ListView` whose rows (`ChatRows.swift`)
    render agent messages with MarkdownView. A row's `height` closure and its `layout()` must agree exactly, or rows
    overlap. AppKit views follow `AppModel` through `Observing`. The window's content is always
    `WorkspaceViewController`: one `GuestStageView` on the left, and on the right the setup panel until the guest is
    ready, then the chat. The setup panel, Settings, the sheets and the error alert stay SwiftUI (`SceneBridge` hosts
    the sheets and alert inside the AppKit window).
11. **macOS 26 guests are set up by walking Setup Assistant.** macOS 26 ignores `VZMacGuestProvisioningOptions`, so
    `HostControl.SetupAssistant` reads each page (Vision) and clicks through it, then turns on SSH and automatic login
    from Terminal (`systemsetup` needs Full Disk Access there; `launchctl` doesn't). Page recognition is tested against
    text from real screens in `Tests/HostControlTests/SetupAssistantScreens`; when Apple changes a page, add its
    fixture (`cc-harness vm up --setup-assistant DIR` saves every screen it reads). The guest agent is built for
    macOS 26 from `Packages/ChatComputerAgentKit`: Launch Services refuses a binary built for a newer macOS
    (-10825), and then the agent never shows in Privacy settings. Keep 27-only APIs out of that package.
    Keep the saved guest password across setup retries. Terminal bootstrap must observe its password prompts
    and verify SSH plus automatic login before it reports success; fixed sleeps are not a readiness check.
    On retries, interrupt the old command and observe a fresh shell marker before sending sudo. A new
    authentication command can otherwise land in the previous sudo password prompt. Bind all markers
    to the current attempt; never answer a stale password or account prompt.
12. **The VM stop request doesn't shut down a macOS guest.** It only opens a dialog. Shut down through the
   agent (`GuestCommand.shutdown`) or `VirtualMachineController.shutDown`. Quitting the app suspends the VM
   (`AppModel.prepareToQuit`); to stop a running app from a script, send SIGTERM, never SIGKILL.
13. **A permission request is not a capture check.** Both the guest menu and bridge use `PermissionSetup`.
    Ordinary retries must not reset TCC or launch duplicate requests. Keep the host's framebuffer observer
    running while a guest capture is pending. Setup completes only after two prompt-free captures show the
    temporary capture-check window. Never persist those images unless the user chose a diagnostic screenshot.
    The temporary window must remain visible above ordinary documents without relying on app activation;
    a restored TextEdit window previously hid its marker and made a usable capture fail verification.
    Hide the captured cursor only while that probe is visible: a pointer over `CC` caused Vision to read `CG`.
    A successful check belongs to its agent version and PID. Invalidate it during onboarding too, clear it
    before any new verification attempt, and query the current identity before freezing or serving an
    external command; a disconnected agent once left an old success visible at onboarding step 5.
    After answering capture consent, re-present the probe with a new marker and discard the earlier
    pixels. Renew the bounded capture budget only once; recurring dialogs must still stop setup.
    Before requesting the next permission, dismiss the previous permission's own consent alert,
    even when health already says granted. In a fresh27 run the old control alert outlived its grant,
    and asking for capture then left the recording list empty.
    Locate a permission row and its switch in the same captured frame. Settings can navigate
    between reads; OCR coordinates from one image must not be applied to another image.
    Coalesce capture checks where their task is created too: checking for an existing task
    before awaiting health leaves a race with the background readiness watcher on cold launch.

## Development switches

These are environment variables, unset in normal use. Launch with `open --env NAME=value build/release/ChatComputer.app`.

| Variable | Effect |
|---|---|
| `CC_DATA_DIR` | Keep all data in this folder instead of the chosen one (hides the choice in setup) |
| `CC_GUEST_PASSWORD` | Known guest password on first boot (at least 4 characters) |
| `CC_AUTO_ONBOARD=1` | Run every setup step in turn |
| `CC_GUEST_MACOS=26` | Choose macOS 26 for the virtual Mac during setup (default 27) |
| `CC_RESTORE_IMAGE` | Install the virtual Mac from this local `.ipsw` instead of downloading one |
| `CC_DEV_MODEL`, `CC_DEV_API_KEY` | Configure the model, e.g. `deepseek:openAI:deepseek-flash` |
| `CC_DEV_TASK` | Submit this task once the guest is ready |
| `CC_DEV_LOG` | Append runner updates to a file, for unattended runs |
| `CC_DEV_CONTINUE=1` | Continue a task restored from the last session once the guest is ready |
| `CC_DEV_WINDOW_SHOTS=1` | Accept `dev_ui` and `dev_window_shot` on the control socket, to drive and capture the app's UI for docs and tests (`dev_ui` actions include `submit`, `cancel`, `continue`, `hostSleep`, `hostWake`, `diagnostics`, `snapshots`, `settings`, `appendChat` for test transcript content, `appearance` light/dark, `dataDirectory` to choose the data folder in setup) |

Permission test actions also include `grantPermissions`, `manualPermissions`, `cancelPermissions`,
`verifyCapture`, `permissionState` and `frameInfo`. `guestKey` (`key`), `guestType` (`text`) and `guestClick`
(`x`, `y` in guest points) use the host's VM input before an agent is available; setup and active tasks must
be stopped first. They are development-only socket actions, not ordinary CLI or MCP tools.
`frameInfo` also reports host activation, the key window and the VM view's keyboard focus.
`dev_window_shot` with `guestOnly: true` writes the host-read guest framebuffer to a 0600 PNG instead
of the whole window, for diagnosing what setup actually reads. It remains gated by `CC_DEV_WINDOW_SHOTS=1`.

All data lives in one folder, `~/.chatcomputer` unless another was chosen in setup (`DataDirectory`; saved as
`DataDirectory` in the `app.chatcomputer.ChatComputer` preferences, which `cc-harness`, `chatcomputer` and the scripts
read too). To drive the app's own VM from `cc-harness`, quit the app and set
`CC_VM_BUNDLE="$HOME/.chatcomputer/ChatComputer.vm"`; both read the bundle's `secrets.json`.
Only one process can run a VM bundle at a time (it is locked). Coding agents can also drive the running app with
`chatcomputer` (see README).

## Safety while operating the VM

- The guest is a disposable test machine, but treat its prompts carefully. Decline permission requests
  the task doesn't need.
- Never type real credentials into the guest. Only use the guest's own test password, from `secrets.json`.
- Before taking screenshots for docs or the website, clear the guest's notifications and permission prompts,
  and don't show the user's own snapshots or files.
- Releases are outward-facing. Publish to GitHub Releases only when the user asks. A release is
  `scripts/release.sh` (notarized), a `vX.Y.Z` tag, `gh release create` with English notes and the zip's SHA-256,
  then `scripts/update-cask.sh X.Y.Z` for the Homebrew cask in `chatcomputer/homebrew-tap`.
