# Mini Slack

A keyboard-first native macOS chat prototype designed to stay useful in narrow
windows.

## What works

- Unread inbox pinned above normal channel and direct-message navigation
- Unreads ranked by mentions first, then latest activity
- Native wide-window sidebar and a focused single-column layout below 700 points
- Conversation history, reactions, composer, mark-read behavior, and settings
- Paginated, disk-cached history with older messages loaded as you scroll upward
- Configurable Off / Slow / Balanced / Fast background history backfill
- Full Slack standard emoji aliases, skin tones, and workspace custom emoji
- Resolved user/channel/broadcast mentions and Slack link/entity text
- Cursor-aware `@` people and `#` channel tagging with native keyboard selection
- Conversation-scoped drafts and native Copy Text message actions
- Quick switcher with an Unreads destination, channel search, and workspace-user DMs
- Live user presence, DND badges, and expiring custom statuses across user surfaces
- Light and dark mode through semantic macOS colors and materials

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Quick switcher | `⌘K` |
| Unread inbox | `⌘⇧U` |
| Next unread | `⌃↓` |
| Previous unread | `⌃↑` |
| Mark conversation read | `⌘⇧R` |
| Move selection | `J` / `K` or `↓` / `↑` |
| Open selection | `L`, `→`, or `Return` |
| Back to Unreads | `H`, `←`, or `Escape` |
| Choose a composer tag | `↑` / `↓`, then `Return` or `Tab` |
| Dismiss composer tags | `Escape` |

Vim and unmodified arrow-key navigation pause automatically while the composer
or quick-switcher search field is active, so typing remains unaffected.
In the composer, type `@` to tag a person or `#` to link a channel. Selected
results keep their readable names in the draft and send Slack's stable IDs.

## Run

Use the Codex `Run` action or:

```sh
./script/build_and_run.sh
```

The script builds the Swift package, stages `dist/MiniSlack.app`, stops an older
instance, and launches the fresh app bundle. The public Slack Client ID is saved
in [`Config/MiniSlack-Info.plist`](./Config/MiniSlack-Info.plist), so no local
environment setup is required.

## Connect a Slack app

1. Create a Slack app from
   [`slack-app-manifest.example.yml`](./slack-app-manifest.example.yml).
2. In **OAuth & Permissions**, confirm PKCE is enabled,
   `minislack://oauth/slack` is registered as a redirect URL, and the manifest's
   user scopes are present.
3. Confirm the app's public **Client ID** is
   `126335682064.11705943614720`.
4. Run `./script/build_and_run.sh`.
5. Choose **Continue with Slack**.

When updating an existing Slack app, add the manifest's `dnd:read` user scope,
reinstall the app to the workspace, and reconnect Mini Slack once so the new
scope is included in the user token.

Slack reports other members as `active` or `away`; only the signed-in user's
detailed response can confirm `offline`. Mini Slack shows `Away` for remote
members instead of guessing that they are offline.

The Client ID is public configuration. Mini Slack uses Slack's native-app PKCE
flow, so no client secret is embedded or required. Access and rotating refresh
tokens are stored in the macOS Keychain.

The app can be tested immediately with its associated development workspace. To
let people install it into other Slack workspaces, enable unlisted distribution
under **Manage Distribution** after the local flow is working. Some workspaces
also require an administrator to approve requested scopes.

## Test

```sh
./script/test.sh
```

The test script uses a temporary SwiftPM build path so macOS File Provider
metadata from the Documents folder cannot interfere with test-bundle signing.

The live connection currently loads workspace users, channels, private channels,
DMs, unread metadata, and recent message history on demand. Sending messages,
opening DMs, and marking conversations read use Slack's Web API. See
[`CAPABILITY_ROADMAP.md`](./CAPABILITY_ROADMAP.md) for the capability-parity plan,
performance guardrails, and Slack platform limits.
