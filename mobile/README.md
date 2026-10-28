# TyresCart Support: Android and iOS app

A native Flutter app for the support team, with a WhatsApp-style chat. It uses the same backend as the website: the
same sign-in, roles, chats, notes and live updates. No screen is a web page.

- Screens and the API each one uses: [API_MAPPING.md](API_MAPPING.md)
- Meta / WhatsApp tokens, the App Secret and the webhook stay on the server. The app only holds the signed-in
  person's own token, in the phone's secure storage.
- The server and the website need no change.

## Build

```bash
cd mobile
flutter pub get

# Android: one APK per processor type (send most phones app-arm64-v8a-release.apk)
flutter build apk --release --split-per-abi --dart-define=API_BASE_URL=https://support.example.com

# iOS (needs an Apple developer account to sign)
flutter build ipa --dart-define=API_BASE_URL=https://support.example.com
```

`API_BASE_URL` is the website's address (the one people open in the browser). The website forwards `/graphql`,
`/socket.io` and the file routes to the API, so the app talks to it exactly like the browser does. Release builds
default to the live server, `https://connect.tyrescart.ae` (debug and release), so plain `flutter run` signs in there.
The sign-in screen never shows the address; for testing, long-press the logo to change it (empty goes back to the
built-in one).

Before publishing to Google Play or the App Store:

- **Android signing**: release builds are signed with the debug key for now (`android/app/build.gradle.kts`). Create
  an upload key and a `key.properties` file, as in https://docs.flutter.dev/deployment/android#sign-the-app.
- **App id**: `tech.synex.tyrescart_support` (Android) and `tech.synex.tyrescartSupport` (iOS). Change it before the
  first upload if you want another one; it can't change afterwards.
- **App icon**: still Flutter's default icon.

## Run on an emulator against a local server

```bash
flutter run   # the live server (https://connect.tyrescart.ae)
```

Debug builds allow plain `http://` for this (`android/app/src/debug/AndroidManifest.xml`).

## Tests

```bash
flutter analyze
flutter test test/rules_test.dart          # the website's rules, same cases as client/lib/*.test.ts

# Against a running DEVELOPMENT server (never production): the API calls and live events the app uses
SUPPORT_TEST_SERVER=http://localhost:4000 flutter test test/live_api_test.dart

# The real app on an emulator or phone, driven screen by screen; screenshots in build/screenshots/
tool/e2e.sh emulator-5554 http://localhost:4000
```

The last two create throwaway test workspaces (`mobile-test-…`, `mobile-e2e-…@example.test`) in the development
database. They only work where the server allows creating workspaces and simulated messages, which production refuses.

## What the app does

- **Chats**: Inbox, My chats, New leads, Collaborations, Mentions and each lifecycle stage, with unread counts. Search,
  status chips (open, snoozed, closed) and "Filter by" (labels, assignees, stages, dates, sort). Pinned chats first.
  Long-press a chat to pin it, mark it unread, or close or reopen it.
- **Chat screen**: text, photos, documents, voice notes (hold the mic), replies, reactions, forward, copy, edit and
  delete (with Undo), message info, delivery ticks, "typing…" from teammates, search in the chat, day separators and
  the chat's timeline.
- **WhatsApp rules**: the 24-hour window (the box becomes "Send template" when it closes), New leads need "Assign to
  me" before replying, and templates need "Yes, Send".
- **Internal notes**: "Add note", with @mentions of teammates and attached files. Notes show as yellow bubbles; you can
  edit and delete them.
- **Chat menu**: assign with a reason, labels, collaborators, snooze, close or reopen, pin, mark unread, clear chat.
- **Contact info**: profile fields, lifecycle stage, lead source, priority, country, subscription, lists, custom
  properties, shared files and notes. Admins can also delete the contact.
- **Alerts**: a pop-up inside the app with a sound, and phone notifications while the app is in the background. They
  cover customer messages in chats you may work on, assignments, @mentions, reminders and new chats. There is also a
  bell with your notification feed, and online, away or offline dots on teammates.
- **Settings**: profile, password, notifications, switch workspace, saved replies and labels. Admins also get message
  templates (list and delete), user management (add, role, activate, label permission), company and workspace
  preferences, simple automations (switches and reply texts) and the assignment report.

## Push notifications (Firebase)

Built in, and off until configured (nothing is registered or sent before that):

- **Server** (`server/src/services/push.ts`): sends with the Firebase Admin SDK (`firebase-admin`) using the service
  account in `server/.env` (`FIREBASE_SERVICE_ACCOUNT_FILE`). The key never leaves the server. Notifies: a customer's
  WhatsApp message of any type (owners, admins and supervisors for every chat; the assignee and collaborators; everyone
  for an unassigned chat), "Chat assigned to you", and @mentions. Each event once per person; tokens Firebase reports
  as gone are deleted.
- **App** (`lib/core/push.dart`): registers this phone's token after sign-in (and on token refresh or a workspace
  switch), removes it on sign-out or when Settings → Notifications → Phone notifications is turned off. In the
  foreground the live connection shows the alert (a push is shown only while that connection is down); in the
  background and when the app is closed the system shows the push. Tapping it opens the chat (also from a closed app).
- **Database**: one new table, `PushDevice` (numeric auto-increment `id`, `token`, `userId`, `workspaceId`,
  `platform`, `createdAt`, `createdBy`, `updatedAt`, `updatedBy`; see `server/backups/push-devices-*.sql`).

To switch it on:

1. Create a Firebase project; add an Android app `tech.synex.tyrescart_support` and an iOS app
   `tech.synex.tyrescartSupport`.
2. Server: Project settings → Service accounts → Generate new private key; put the file on the server (outside the
   repo) and set `FIREBASE_SERVICE_ACCOUNT_FILE` to its path; restart the API.
3. App: put the Firebase keys in `env/prod.json` (see `env/README.md`) and rebuild.
4. iOS only: a **paid** Apple Developer team (personal teams can't use push). In Apple Developer → Keys, create an
   APNs key and upload it in Firebase → Project settings → Cloud Messaging → Apple app configuration. In Xcode, open
   `ios/Runner.xcworkspace` → Runner target → Signing & Capabilities: choose the paid team, add **Push Notifications**
   (it uses `ios/Runner/Runner.entitlements`, already in the project folder). Background Modes → Remote notifications
   is already on.

## Known limits

- **Push notifications** need the Firebase setup above (and, for iPhones, a paid Apple Developer team). Until then
  alerts arrive while the app is open or recently in the background.
- **Voice notes from customers on iPhone**: WhatsApp sends them as OGG/Opus, which iOS can't play. They play on
  Android. On iPhone, open the file from Contact info → Media in another app.
- **Website only**: creating and editing message templates, working hours and who gets new chats (Simple
  automations), lifecycle stages, contact properties, contact lists, restoring deleted contacts, connecting the
  WhatsApp number, the WhatsApp QR code and CSV report export. Use the website for these.
