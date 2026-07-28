# Capability parity

Mini Slack keeps its compact, keyboard-first interface while working toward every
Slack capability available to a third-party macOS client. The target is
capability parity, not Slack's layout.

## Performance guardrails

- Keep command and keyboard navigation local; opening the quick switcher must not
  wait on network, disk, sorting, or image work.
- Prepare message entities and standard emoji when a history page arrives, not
  while a row is scrolling.
- Keep histories and selectors lazy with stable identities and bounded page
  sizes.
- Cache normalized data on disk and retain only active working sets in memory.
- Decode and downsample remote images away from the main actor.
- Measure release builds with Instruments before accepting features that touch
  message lists, search, synchronization, or image loading.

## Message fidelity

- [x] Standard Slack emoji aliases and exact skin-tone variants
- [x] Workspace custom emoji and aliases
- [x] User, channel, and broadcast mention resolution
- [x] Slack links, escaped entities, date fallbacks, and user-group fallbacks
- [x] Semantic rich-text blocks, including lists, quotes, code, and styles
- [x] Attachments, files, image previews, unfurls, and bot/app messages
- [x] Edited/deleted states and message delivery status
- [x] Avatars plus presence, custom status, and DND across user surfaces

## Conversation and message actions

- [x] Send messages and mark conversations read
- [x] Conversation-scoped drafts
- [x] Copy rendered message text
- [x] Edit and delete owned messages
- [x] Add and remove reactions
- [x] Local saved messages, pins, reminders, and Slack permalinks
- [ ] Slack-synchronized Save Later
- [x] Create, join, leave, and manage channels
- [x] Start group DMs and replace participant sets with a new group DM

## Threads, search, and activity

- [x] Paginated thread replies with a compact thread pane
- [x] Reply counts, participant previews, and followed-thread state
- [x] Instant current-conversation find
- [x] Offline workspace full-text search
- [x] Remote message/file search plus local person/channel search
- [x] Mentions, reactions, and followed-thread activity inbox
- [x] Conversation-header unread bell with a bounded jump-to-message dropdown

## Composer and files

- [x] User and channel autocomplete with semantic Slack IDs
- [x] Emoji autocomplete
- [x] Formatting controls, code blocks, and per-thread drafts
- [x] Scheduled messages
- [x] File upload, download, Quick Look, drag/drop, and pasted screenshots

## Synchronization and macOS integration

- [x] Normalized local database for messages, thread metadata, files, reactions,
      read cursors, and full-text search
- [x] Incremental sync coordinator with Slack-aware rate limiting and retries
- [x] Rate-aware polling fallback for incremental message updates
- [x] Per-conversation unread bootstrap from Slack read cursors and bounded history
- [x] Direct desktop Socket Mode ingestion for self-managed Slack apps
- [x] Durable offline outgoing-message queue with conservative replay
- [x] Durable root-message edit/delete queue with conflict reconciliation
- [ ] Durable queued edit/delete for lazily loaded thread replies
- [x] Native notifications, dock badge, local mute rules, and DND suppression
- [x] Multiple saved accounts with safe workspace switching
- [ ] Simultaneous per-window workspace sessions
- [x] Current-user custom status, manual presence, and DND editing

## Platform boundary

Some first-party Slack capabilities are not exposed to third-party clients.
Literal parity for Huddles, Slack AI, enterprise administration, and arbitrary
interactions owned by other Slack apps is therefore outside the public API
boundary. Slack's public API also does not expose the current Save Later
workflow; the legacy
[`stars.add`](https://docs.slack.dev/reference/methods/stars.add/) API is
deprecated, so Mini Slack keeps saved messages locally per workspace.

Mini Slack uses direct desktop
[Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/) with a
Keychain-stored app-level token for self-managed Slack apps. Rate-aware polling
remains active as a recovery path, and
[`conversations.history`](https://docs.slack.dev/reference/methods/conversations.history/)
has distribution-dependent rate limits.
