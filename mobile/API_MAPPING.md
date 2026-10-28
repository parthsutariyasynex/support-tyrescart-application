# TyresCart Support (Flutter): screen-to-API mapping

The app talks to the same backend as the website, through the same public address. The Next.js server already
forwards `/graphql`, `/socket.io`, `/auth/*` and every upload/download path below to the Node.js API, so the app
needs no server change. All Meta / WhatsApp calls, tokens, the App Secret and the webhook stay on the server.

Sign-in is the same JWT the website uses (`Authorization: Bearer <token>`, Socket.IO `auth.token`). It is kept in
the phone's secure storage (Keychain / Android Keystore).

| Screen | Reads | Writes | Live (Socket.IO) |
|---|---|---|---|
| Sign in | — | `login(input)` (GraphQL) | — |
| Forgot password | — | `requestPasswordReset(email)` | — |
| App start / session | `me { user workspace role canManageLabels canManageAssignments }`, `workspaces` | `switchWorkspace(id)` | `member:permissions`, `member:removed`, `workspace:renamed` |
| Chat list (Inbox, My chats, New leads, Collaborations, Mentions, Lifecycle stage) | `conversations(first, after, assignee, status, search, sort, labelIds, assigneeIds, from, to, leadStage, leadStages)`, `conversationCounts`, `leadStageCounts(chats: true)` | — | `message:new`, `message:status`, `message:updated`, `conversation:status`, `conversation:assigned`, `conversation:labels`, `conversation:pinned`, `conversation:unread`, `conversation:started`, `conversation:cleared`, `contact:updated`, `contact:deleted`, `contact:restored`, `mention:you`, `mentions:changed`, `typing` |
| Chat list: long-press actions | — | `pinConversation` / `unpinConversation`, `markConversationUnread`, `closeConversation` / `reopenConversation` | as above |
| Filter sheet | `labels`, `assignees`, `contactFieldOptions.leadStages` | — | `label:saved`, `label:deleted`, `assignee:saved`, `assignee:deleted` |
| New chat | — | `startConversation(input)` | `conversation:started` |
| Chat screen: messages | `conversation(id)`, `messages(conversationId, first, after)` (paged, newest page first), `conversationActivity` | `markConversationRead(id)` | `message:new`, `message:status`, `message:updated`, `typing` (sent and received) |
| Chat screen: internal notes | `chatNotes(conversationId)`, `workspaceMembers` (for @) | `addContactRemark(contactId, body, mentions, files)`, `updateContactRemark`, `deleteContactRemark`, `POST /inbox/contacts/:id/remark-files?name=` (raw file body), `GET /inbox/remark-files/:id` | `contact:remarks` |
| Composer: text, reply | `quickReplies(search)` (typing `/`) | `sendTextMessage(input { conversationId body replyToId })` | — |
| Composer: photo / document | — | `POST /inbox/conversations/:id/images?caption=&replyTo=`, `POST /inbox/conversations/:id/documents?name=&caption=&replyTo=` (raw file body) | — |
| Composer: voice note | — | `POST /inbox/conversations/:id/voice?replyTo=` (audio/mp4 body) | — |
| Templates (24-hour window closed, or Template button) | `messageTemplates` (approved only, `hello_world` hidden), `contact(id)` for the name | `sendTemplateMessage(input { …, confirmed: true, requestId })`; media header: `POST /inbox/conversations/:id/template?name=&language=&values=&fileName=&confirmed=true&requestId=` | `templates:changed` |
| Message actions | — | `reactToMessage`, `editMessage`, `deleteMessage`, `restoreMessage`; forward = the send calls above | `message:updated` |
| Media viewer / downloads | `GET /inbox/messages/:id/media` (Bearer) | — | `message:updated` (customer file finished downloading) |
| Chat menu | `assignees`, `workspaceMembers`, `labels`, `conversation.collaborators` | `claimConversation` (Assign to me), `assignConversation(…, reason)`, `addConversationLabel` / `removeConversationLabel`, `addCollaborators` / `removeCollaborator`, `snoozeConversation(until)`, `closeConversation`, `reopenConversation`, `pinConversation`, `markConversationUnread`, `clearConversation` | `conversation:collaborators`, `assignment:you`, `assignment:removed` |
| Contact info | `contact(id)`, `contactFieldOptions`, `contactRemarks`, `chatFiles`, `contactLists`, `customProperties`, `conversation { channel lastOutboundAt lastInboundAt }` | `updateContact(id, input)`, `addContactToList` / `removeContactFromList`, `setContactCustomValue`, `deleteContact` (admins) | `contact:updated`, `contact:lists`, `contact:remarks` |
| Notifications (bell) | `notifications(first)`, `unreadTotal` | `markNotificationsSeen` | `notification:new`, `mention:you`, `assignment:you`, `assignment:reminder`, `chat:new` |
| Settings: profile | `me` | `updateMyProfile(input)`, `changeMyPassword` | — |
| Settings: notifications | (stored on the phone) | — | — |
| Settings: workspace switch | `workspaces` | `switchWorkspace(id)` | — |
| Settings: labels | `labels` | `createLabel`, `updateLabel`, `deleteLabel` (needs `canManageLabels`) | `label:saved`, `label:deleted` |
| Settings: saved replies | `quickReplies(first: 100)` | — | — |
| Settings: message templates (admins) | `allMessageTemplates` | `deleteMessageTemplate` | `templates:changed` |
| Settings: team (admins) | `members` | `inviteMember`, `updateMemberRole`, `setMemberActive`, `updateMember` | `member:removed` |
| Settings: workspace preferences / company (admins) | `workspaceSettings` | `updateWorkspaceSettings`, `renameWorkspace` | `workspace:settings` |
| Settings: simple automations (admins) | `automationSettings` | `updateAutomationSettings` | — |
| Settings: assignment report (admins) | `assignmentReport(from, to, first)` | — | — |
| Presence | Socket.IO `presence:list` (ack) | Socket.IO `presence:activity` | `presence:update` |
| Push notifications (this phone) | `pushConfigured` | `registerPushDevice(token, platform)` after sign-in / token refresh, `unregisterPushDevice(token)` on sign-out | FCM (sent by the server): customer message, assigned to you, @mention; data `conversationId` opens the chat |

## Rules the app follows (the server enforces them too)

- **24-hour window**: free text, files and voice notes only within 24 hours of `lastInboundAt`; otherwise the
  composer becomes "Send template". A `WINDOW_CLOSED` refusal switches it at once.
- **New leads**: an agent must "Assign to me" (`claimConversation`) before replying (`NOT_ASSIGNED`); owners, admins
  and supervisors can reply directly. Anyone can add an internal note.
- **Templates** are sent only after "Yes, Send", with a one-time `requestId`, so a retry never sends twice.
- **Limits**: 4,096 characters per message, 1,024 per caption, the server's `remarkMaxLength` per note; images
  JPEG/PNG up to 5 MB, documents up to 100 MB, voice up to 16 MB. Text over a limit is never cut.
- **Roles**: assign/reassign only with `canManageAssignments`; label management with `canManageLabels`; edit and
  delete only your own sent messages (owners/admins: any).

## Push notifications

The server sends them through Firebase Cloud Messaging (service account in `server/.env`, never in the app); off until
configured. See the README's "Push notifications" section.
