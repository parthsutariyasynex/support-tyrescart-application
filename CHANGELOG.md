# Changelog

All notable changes to TyresCart Support Chat (client and server) are written here, newest first.

- Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Sections: **Added**, **Changed**, **Fixed**,
  **Removed**, **Security**, plus **Deploy notes** whenever production needs a step (database SQL, env, config).
- Each entry describes what users (agents, admins) notice, not how the code does it. Commit hashes are given so the
  details can be looked up with `git show <hash>`.
- New work goes under **[Unreleased]**. When it's deployed to production, rename that heading to the deploy date and
  start a new empty **[Unreleased]** above it.

## [Unreleased]

### Added
- **Mobile app: KL logo and WhatsApp-style counts.** The app icon (Android and iOS), the sign-in screen and the
  notification icon use the KL logo. Unread counts are WhatsApp green on the Chats and
  Updates tabs, and the app's icon shows the number of unread customer messages (iOS, and Android launchers that show
  counts).
- **Push notifications for the mobile app** (Firebase Cloud Messaging), off until Firebase is configured: a customer's
  WhatsApp message of any type (to its assignee and collaborators, admins and supervisors, or everyone for a new
  chat), "Chat assigned to you" and @mentions reach the phone when the app is in the background or closed; tapping one
  opens the chat. Each push also updates the number on the app's icon (unread messages), even while the app is closed. Phones register after sign-in and are removed on
  sign-out. See `mobile/README.md`.
- **Mobile app (Android and iOS)** in `mobile/`: a native Flutter app for the team with a WhatsApp-style chat, using
  the same server, sign-in, roles and live updates as the website. It has the chat lists (Inbox, My chats, New
  leads, Collaborations, Mentions, lifecycle stages), search and filters. The chat screen has text, photos,
  documents, voice notes, replies, reactions, forward, edit and delete. It also has templates with "Yes, Send", the
  24-hour window, internal notes with @mentions and files, the chat menu (assign with reason, labels,
  collaborators, snooze, close, pin), contact info, the bell, alerts and settings. Admins get templates, users,
  preferences, automations and the assignment report. See `mobile/README.md` and `mobile/API_MAPPING.md`.

### Deploy notes
- **Push notifications** (when switching them on): run `server/backups/push-devices-20261026-165321.sql` on production
  (new table `PushDevice` only; back up first), set `FIREBASE_SERVICE_ACCOUNT_FILE` in the server's `.env`, restart the
  API. Without it, push stays off and nothing else changes.
- The server and website don't change. Build the app with `--dart-define=API_BASE_URL=<the website's HTTPS
  address>`. Android release signing and the app icon still need to be set up before publishing (see
  `mobile/README.md`).

## 2026-10-23

### Added
- **Internal notes in the chat**: "Add note" next to Reply. Notes show as yellow "Internal note" bubbles between the
  messages, live for the whole team, and are never sent to WhatsApp or the customer. (`b78a5d8`)
- **@mentions in notes**: typing `@` suggests teammates (name and email). The person mentioned gets a pop-up, a 🔔
  entry that stays while they are offline, and the chat in the new **Mentions** inbox (left menu). (`b78a5d8`)
- **Files on notes**: 📎 in Add note attaches images and documents; only signed-in teammates can open them.
  (`b78a5d8`)
- Agents can add a note on an unassigned New Lead (replying still needs "Assign to Me"). (`b78a5d8`)
- **New chat** button in the chat list: country code + number, checked as you type; an existing customer opens their
  chat instead of a duplicate; new chats appear for everyone live. (`9537f21`)
- Browser tab icon (favicon) with the TyresCart logo. (`9537f21`)
- **Templates in the chat**: Template button above the message box; choosing a template shows just the message with
  the customer's name filled in; sending asks **"Yes, Send"**; only the account's approved templates are listed
  (Meta's `hello_world` sample is hidden). (`b20fd33`)
- **24-hour WhatsApp window**: after 24 hours since the customer last wrote, the message box is replaced by "Send
  template"; a new customer message opens it again. Enforced on the server for every role. (`b20fd33`)
- Stage filter in the chat list's "Filter by" menu. (`060db9b`)
- New-message pop-ups on every page with sound (on/off in Settings → Notifications) and desktop notifications in the
  background, only for chats you may work on. (`060db9b`)
- Customer country code drop-down (🇮🇳 +91) in the chat header and the profile. (`060db9b`)
- **Esc** closes the open chat, like WhatsApp Web. (`060db9b`)
- Opening a chat puts the cursor in the message box. (`060db9b`)

### Changed
- Editing a note updates its mentions; deleting a note removes them from Mentions and the 🔔. (`b78a5d8`)
- Message length limits are only WhatsApp's or the database's (4,096 per message, 16,000 per note); text over a limit
  is kept and explained, never cut. (`b20fd33`)

### Fixed
- Auto-reply is no longer sent after the 24-hour window has closed (e.g. a webhook Meta delivered late). (`6fa7836`)
- Meta's own notices (`system`, `request_welcome`) are no longer treated as customer messages: no chat bubble, no
  unread, no auto-reply. (`6fa7836`)
- The chat screen and the server always agree on whether the 24-hour window is open; a server refusal switches the
  box to "Send template" at once. (`6fa7836`)

### Removed
- "Follow-up after 24 hours" automation: templates are never sent automatically any more. (`b20fd33`)

### Deploy notes
- **Database**: run `server/backups/remark-files-20261023-162253.sql` on production (new table `RemarkFile`; nothing
  else changes). Back up first.
- **Client config**: deploy `client/next.config.ts` with the client (new `/inbox/contacts/:id/remark-files` and
  `/inbox/remark-files/:id` rewrites; without them, note files fail to upload).
- Until this is deployed, production still runs the old "Follow-up after 24 hours" automation.

## 2026-10-22

### Added
- Desktop notifications for new customer messages and WhatsApp template support. (`1bf80f6`)

### Fixed
- Customer messages kept out of the 🔔; an alert for each new message. (`1394344`)
- Notifications for chats other than the open one; Socket.IO WebSocket upgrade. (`1cd3ee2`)

## 2026-10-21

### Added
- Paste an image into the chat to send it.
- Auto-reply settings and message reactions in the chat. (`12855c1`)

### Changed
- All dates and times shown in Dubai time; the chat follows new messages. (`27972fe`)

## 2026-10-16

### Added
- Settings, contacts, voice notes and media completed.
- Network-error retry screen when the backend restarts; zero-downtime deploys.

### Fixed
- Layout shifts and clipped pop-overs.

## 2026-10-15

### Added
- App-wide toasts, saved assignment reminders, collaborators, chat filters, snooze and pinned chats.

### Fixed
- Reminders keep going for unclaimed leads after they are viewed. (`ad27eae`)
- One failing message in a webhook batch no longer drops the others; diagnostics for rejected signatures.

## 2026-10-14

### Added
- Online/away presence, assignment reminders, reports.

## 2026-10-13

### Added
- New Leads and admin features; permissions, role editing and user creation by admins.

### Security
- `server/backups/` no longer tracked in git (it held real customer data and password hashes).
- Dangerous assignee migration script removed; the safe one hardened.

## 2026-10-12

### Added
- Roles (owner/admin, supervisor, agent) enforced on GraphQL, REST and Socket.IO; team management, Assign drop-down,
  My Chats, quick replies (`/` in the message box), approved template picker, phone number validation, Dubai time
  with date separators.

## 2026-10-10

### Added
- Chat start and WhatsApp webhook; labels, assignment, notifications, activity history, forgot password.

### Fixed
- Backend port in `ecosystem.config.cjs` and the client proxy (5000).

## 2026-10-09

### Added
- First version of the TyresCart support chat (project setup).
