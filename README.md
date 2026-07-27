# Mini Slack

A keyboard-first native macOS chat prototype designed to stay useful in narrow
windows.

## What works

- Unread inbox pinned above normal channel and direct-message navigation
- Unreads ranked by mentions first, then latest activity
- Rate-aware channel unread bootstrap with native notifications and dock badges
- Native wide-window sidebar and a focused single-column layout below 700 points
- Conversation history, reactions, composer, mark-read behavior, and settings
- Paginated SQLite-backed history with older messages loaded as you scroll upward
- Configurable Off / Slow / Balanced / Fast background history backfill
- Full Slack standard emoji aliases, skin tones, and workspace custom emoji
- Resolved user/channel/broadcast mentions and Slack link/entity text
- Cursor-aware `@` people and `#` channel tagging with native keyboard selection
- Conversation-scoped drafts and native Copy Text message actions
- Quick switcher with an Unreads destination, channel search, and workspace-user DMs
- Compact threads, Activity, local Saved, scheduled messages, uploads, and workspace search
- Message edit/delete, reactions, pins, reminders, permalinks, and delivery state
- Multiple saved Slack workspaces with session-safe switching
- Direct Socket Mode delivery with rate-aware polling recovery
- Live user presence, DND badges, and expiring custom statuses across user surfaces
- Light and dark mode through semantic macOS colors and materials

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Quick switcher | `⌘K` |
| Find in conversation | `⌘F` |
| Search workspace | `⌘⇧F` |
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
instance, and launches the fresh app bundle.

## Connect a Slack app

On first launch, Mini Slack walks through the complete setup:

1. Open Slack's app dashboard and create an app from a manifest.
2. Copy or export the ready
   [`slack-app-manifest.example.yml`](./slack-app-manifest.example.yml).
3. Generate an app-level token with `connections:write`.
4. Paste the app's public Client ID and `xapp-…` token into Mini Slack.
5. Save the setup, then choose **Continue with Slack**.

When updating an existing Slack app, sync every user scope from the example
manifest, reinstall the app to the workspace, and reconnect Mini Slack once so
the expanded permissions are included in the user token. Existing tokens do not
gain newly added scopes automatically.

Slack reports other members as `active` or `away`; only the signed-in user's
detailed response can confirm `offline`. Mini Slack shows `Away` for remote
members instead of guessing that they are offline.

The Client ID is public configuration. Mini Slack uses Slack's native-app PKCE
flow, so no client secret is embedded or required. The Client ID, app-level
token, access tokens, and rotating refresh tokens are stored in macOS Keychain.
Socket Mode events are acknowledged and applied directly; polling stays enabled
as a recovery path for missed events.

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

The live connection loads workspace users, channels, private channels, DMs,
unread metadata, and recent message history on demand. Background work is
rate-aware, histories and search indexes are bounded in memory, and durable
history/search state is stored per workspace. See
[`CAPABILITY_ROADMAP.md`](./CAPABILITY_ROADMAP.md) for the capability-parity plan,
performance guardrails, and Slack platform limits.
