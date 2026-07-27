# Mini Slack Agent Guide

## Project overview

Mini Slack is a keyboard-first native macOS Slack client designed to remain
useful in narrow windows. It is a Swift 6.2 Swift Package targeting macOS 14 and
uses SwiftUI, SQLite, and `EmojiText`.

Preserve these product constraints:

- Keep the compact single-column experience usable below 700 points.
- Keep Unreads as the primary landing and navigation surface.
- Preserve keyboard and Vim-style navigation.
- Keep message histories, search indexes, and background work bounded.
- Keep workspace data, credentials, caches, and delayed async results isolated
  to the active workspace session.
- Use semantic macOS colors and native desktop behavior in light and dark mode.

`CAPABILITY_ROADMAP.md` is the source of truth for implemented capabilities,
performance guardrails, and known Slack public API limits.

## Technology

- Swift 6.2 with strict concurrency
- SwiftUI and targeted AppKit interop
- Swift Package Manager
- macOS 14+
- SQLite for durable history and full-text search
- Slack Web API, OAuth PKCE, Socket Mode, and polling recovery
- macOS Keychain for app tokens and workspace credentials

The package produces two executables:

- `MiniSlack`: the main app
- `MiniSlackKeychainHelper`: the stable Keychain access helper

## Folder structure

```text
Config/
  MiniSlack-Info.plist          App bundle metadata
Sources/
  MiniSlack/
    App/                        App entry point and app lifecycle
    Models/                     Value types and feature state
    Services/                   Slack APIs, persistence, networking, Keychain
    Stores/                     AppStore and feature-specific state mutations
    Support/                    Parsing, formatting, navigation, and small helpers
    Views/                      SwiftUI feature and component views
  MiniSlackKeychainHelper/      Keychain helper executable
Tests/
  MiniSlackTests/               Swift Testing suites by feature
script/
  build_and_run.sh              Build, bundle, sign, launch, and verify
  test.sh                       Full test suite with a safe SwiftPM scratch path
dist/                           Generated runnable app bundle; do not edit
```

Follow the existing responsibility boundaries:

- Slack payload decoding belongs in `Services`.
- Durable or display-ready domain data belongs in `Models`.
- Parsing and text normalization belong in `Support`.
- Workspace-aware mutations and async coordination belong in `Stores`.
- Rendering and local interaction state belong in `Views`.

Trace message bugs through the complete path:

1. Slack DTO decoding
2. DTO-to-`Message` conversion
3. display preparation and cache round trips
4. the relevant SwiftUI message view

Slack apps frequently mix `rich_text`, standard Block Kit, legacy attachments,
and Block Kit nested inside attachments. Test the payload shape that actually
failed rather than assuming a top-level shape.

## Building and running

Always launch development builds through:

```sh
./script/build_and_run.sh
```

Do not use `swift run`, launch a `.build` binary directly, or manually assemble
the app bundle. The script:

- stops an existing Mini Slack process;
- incrementally builds the main app and Keychain helper;
- stages `dist/MiniSlack.app`;
- signs both executables with a stable identity;
- validates the signature; and
- launches the newly built bundle with a clean environment.

The stable signing identity preserves access to Slack credentials stored in
Keychain. A direct or ad-hoc launch can produce repeated Keychain prompts or an
apparently disconnected app.

Supported modes:

```sh
./script/build_and_run.sh                 # Debug build and launch
./script/build_and_run.sh --verify        # Launch and confirm the process stays up
./script/build_and_run.sh --release       # Optimized build and launch
./script/build_and_run.sh --lldb          # Build and launch under LLDB
./script/build_and_run.sh --logs          # Launch and stream process logs
./script/build_and_run.sh --telemetry     # Launch and stream app telemetry
```

If another checkout contains a Mini Slack bundle with the same bundle
identifier, UI automation can target the wrong app. Target this checkout
explicitly:

```text
/Users/hamsti/projects/mini-slack/dist/MiniSlack.app
```

## Testing

Every behavior change requires a regression test. Use Swift Testing and place
the test in the existing feature suite under `Tests/MiniSlackTests`.

Run the complete suite before finishing:

```sh
./script/test.sh
```

The script uses `/private/tmp/mini-slack-swiftpm` because a normal SwiftPM build
path can inherit macOS metadata that breaks test-bundle signing. Prefer the
script over bare `swift test`.

For a focused edit loop, use the same scratch path:

```sh
swift test \
  --package-path "$PWD" \
  --scratch-path /private/tmp/mini-slack-swiftpm \
  --filter MessageMediaTests
```

Focused tests do not replace the full suite.

## Required validation

Before handing off a code change:

1. Add or update a regression test for the actual failure seam.
2. Run the focused test while iterating.
3. Run `./script/test.sh`.
4. Run:

   ```sh
   git diff --check
   bash -n script/test.sh
   bash -n script/build_and_run.sh
   ```

5. Run `./script/build_and_run.sh --verify`, or use
   `./script/build_and_run.sh` when live UI verification is required.
6. For rendering or interaction changes, navigate to the real affected surface
   in the rebuilt app and confirm the behavior. A synthetic decoding test alone
   is not sufficient.

This repository does not currently configure SwiftLint or a Swift formatter.
Preserve the established four-space formatting and do not run a formatter
across unrelated files.

## Implementation rules

- Make the narrowest change that preserves existing working behavior.
- Do not rewrite unrelated dirty-worktree changes.
- Keep comments rare and explain why, not what.
- Avoid speculative null handling, unnecessary abstractions, and broad
  `do`/`catch` wrappers.
- Keep network work, image decoding, and disk work off the main actor.
- Validate workspace session generation before applying delayed async results.
- Never log or print Slack tokens, refresh tokens, app-level tokens, or Keychain
  values.
- Preserve raw Slack identifiers alongside display-ready text when later
  re-resolution, mutation, or navigation needs them.
- Treat cached-model compatibility as part of a model change; old cached
  messages should continue to decode with sensible defaults.
- Keep message rows lazy and avoid unbounded view or model work during scrolling.

## UI expectations

- Preserve the existing compact native design instead of introducing a new
  visual system.
- Test both narrow and wide windows when changing layout.
- Keep long app messages collapsed with an explicit expansion control.
- Keep links, text selection, accessibility labels, and keyboard paths working.
- Use system-adaptive colors and materials.
- Do not start a separate development server; Mini Slack is a native app.
