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
- [ ] Semantic rich-text blocks, including lists, quotes, code, and styles
- [ ] Attachments, files, image previews, unfurls, and bot/app messages
- [ ] Edited/deleted states and message delivery status

## Conversation and message actions

- [x] Send messages and mark conversations read
- [x] Conversation-scoped drafts
- [x] Copy rendered message text
- [ ] Edit and delete owned messages
- [ ] Add and remove reactions
- [ ] Save, pin, remind later, and copy a Slack permalink
- [ ] Create, join, leave, and manage channels
- [ ] Start group DMs and manage members

## Threads, search, and activity

- [ ] Paginated thread replies with a compact thread pane
- [ ] Reply counts, participant previews, and followed-thread state
- [ ] Instant current-conversation find
- [ ] Offline workspace full-text search
- [ ] Remote message, file, person, and channel search
- [ ] Mentions, reactions, and thread activity inbox

## Composer and files

- [x] User and channel autocomplete with semantic Slack IDs
- [ ] Emoji autocomplete
- [ ] Formatting controls, code blocks, and per-thread drafts
- [ ] Scheduled messages
- [ ] File upload, download, Quick Look, drag/drop, and pasted screenshots

## Synchronization and macOS integration

- [ ] Normalized local database for messages, threads, files, reactions, and
      read cursors
- [ ] Incremental sync coordinator with Slack-aware rate limiting and retries
- [ ] Real-time event ingestion with polling fallback
- [ ] Offline mutation queue and conflict reconciliation
- [ ] Native notifications, dock badge, mute rules, and DND
- [ ] Multiple isolated workspaces
- [ ] Profile, presence, and status editing

## Platform boundary

Some first-party Slack capabilities are not exposed to third-party clients.
Literal parity for Huddles, Slack AI, enterprise administration, and arbitrary
interactions owned by other Slack apps is therefore outside the public API
boundary. Real-time delivery also requires either
[Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/) or a
hosted Events API service, and
[`conversations.history`](https://docs.slack.dev/reference/methods/conversations.history/)
has distribution-dependent rate limits.
