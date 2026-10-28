// Push notifications (Firebase Cloud Messaging through the Firebase Admin SDK), fully isolated:
//   - no database: the Prisma client is pointed at an address where nothing listens, and the tables push uses
//     (PushDevice, Member, ConversationCollaborator, and the unread total from Conversation) are in-memory fakes; any
//     other query fails to connect
//   - no Firebase: sends go to a fake sender in this process; the test checks no Firebase app was ever started
//
//   npx tsx --test test/push.test.ts
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { after, before, test } from 'node:test';
import type { Message } from 'firebase-admin/messaging';
import { fakeTable } from './pushFakes.js';

// Before anything loads the server's .env (dotenv never overrides a variable already set)
const DEAD_DB = 'mysql://isolated:none@127.0.0.1:1/push_test_isolated';
process.env.DATABASE_URL = DEAD_DB;
process.env.FIREBASE_SERVICE_ACCOUNT_FILE = ''; // never the real key

type Sent = { token: string; title: string; body: string; data: Record<string, string>; tag: string; channel: string; collapseId: string; threadId: string; iosBadge?: number; androidCount?: number };
const sent: Sent[] = [];
const GONE = 'gone-token-0000000000000000000000';
const BROKEN = 'broken-token-000000000000000000000';

// Stands in for Firebase: records what would be sent, and answers like FCM for a removed app or an outage
const fakeSender = {
  async send(m: Message) {
    if (!('token' in m)) throw new Error('push must target one device token');
    if (m.token === GONE) throw Object.assign(new Error('Requested entity was not found.'), { code: 'messaging/registration-token-not-registered' });
    if (m.token === BROKEN) throw Object.assign(new Error('Service unavailable'), { code: 'messaging/server-unavailable' });
    sent.push({
      token: m.token,
      title: m.notification?.title ?? '',
      body: m.notification?.body ?? '',
      data: m.data ?? {},
      tag: m.android?.notification?.tag ?? '',
      channel: m.android?.notification?.channelId ?? '',
      collapseId: String(m.apns?.headers?.['apns-collapse-id'] ?? ''),
      threadId: String(m.apns?.payload?.aps?.threadId ?? ''),
      iosBadge: m.apns?.payload?.aps?.badge,
      androidCount: m.android?.notification?.notificationCount,
    });
    return 'projects/push-test/messages/1';
  },
};

const ws = 'ws-push-test';
const users = { owner: 'u-owner', supervisor: 'u-supervisor', agentA: 'u-agentA', agentB: 'u-agentB', collab: 'u-collab', inactive: 'u-inactive' };
const devices = fakeTable([], { autoId: true });
const members = fakeTable([
  { id: 'm-owner', userId: users.owner, workspaceId: ws, role: 'owner', active: true },
  { id: 'm-supervisor', userId: users.supervisor, workspaceId: ws, role: 'supervisor', active: true },
  { id: 'm-agentA', userId: users.agentA, workspaceId: ws, role: 'agent', active: true },
  { id: 'm-agentB', userId: users.agentB, workspaceId: ws, role: 'agent', active: true },
  { id: 'm-collab', userId: users.collab, workspaceId: ws, role: 'agent', active: true },
  { id: 'm-inactive', userId: users.inactive, workspaceId: ws, role: 'agent', active: false },
  { id: 'm-other', userId: 'u-elsewhere', workspaceId: 'ws-other', role: 'owner', active: true },
]);
const collaborators = fakeTable([]);
// The workspace's unread total (Conversation.unread summed), as the server's unreadTotal() reads it
let unreadSum: number | Error = 7;
const conversations = {
  aggregate: async () => {
    if (unreadSum instanceof Error) throw unreadSum;
    return { _sum: { unread: unreadSum } };
  },
};

let push: typeof import('../src/services/push.js');
let firebaseApps: () => unknown[];
const tok = (who: string) => `fcm-${who}-0000000000000000`;
const auth = (who: keyof typeof users) => ({ userId: users[who], workspaceId: ws });

/** Waits for the sends to land, then takes what arrived */
async function take(min: number, wait = 1000) {
  const end = Date.now() + wait;
  while (sent.length < min && Date.now() < end) await new Promise((r) => setTimeout(r, 10));
  await new Promise((r) => setTimeout(r, 50)); // anything extra that shouldn't have been sent
  return sent.splice(0);
}

before(async () => {
  // A throwaway service account (never used to sign in: the fake sender replaces Firebase)
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } });
  process.env.FIREBASE_SERVICE_ACCOUNT = JSON.stringify({ project_id: 'push-test', client_email: 'push@test.iam', private_key: privateKey });

  const { prisma } = await import('../src/prisma.js');
  assert.equal(process.env.DATABASE_URL, DEAD_DB, 'the Prisma client must not see a real database address');
  for (const [model, fake] of [['pushDevice', devices], ['member', members], ['conversationCollaborator', collaborators], ['conversation', conversations]] as const) {
    Object.defineProperty(prisma, model, { value: fake, configurable: true });
  }
  // Proof of isolation: anything not faked can't reach a database
  await assert.rejects(prisma.workspace.findFirst(), /127\.0\.0\.1:1/);

  push = await import('../src/services/push.js');
  push.setPushSenderForTests(fakeSender);
  const { getApps } = await import('firebase-admin/app');
  firebaseApps = getApps;
});

after(() => {
  assert.equal(firebaseApps().length, 0, 'no Firebase app was started: nothing could reach Firebase');
});

test('devices: registered by the signed-in person (numeric id, createdBy/updatedBy), moved on re-registration, removed on sign-out', async () => {
  assert.equal(push.pushConfigured(), true);
  for (const who of Object.keys(users) as (keyof typeof users)[]) assert.equal(await push.registerPushDevice(auth(who), { token: tok(who), platform: 'android' }), true);
  assert.equal(devices.rows.length, 6);
  const first = await devices.findUnique({ where: { token: tok('owner') } });
  assert.equal(typeof first?.id, 'number');
  assert.equal(first?.createdBy, users.owner);
  assert.equal(first?.updatedBy, users.owner);
  // A phone signed in by someone else now belongs to them (same row, updatedBy is the new person)
  assert.equal(await push.registerPushDevice(auth('agentA'), { token: tok('agentB'), platform: 'ios' }), true);
  const moved = await devices.findUnique({ where: { token: tok('agentB') } });
  assert.equal(moved?.userId, users.agentA);
  assert.equal(moved?.platform, 'ios');
  assert.equal(moved?.createdBy, users.agentB);
  assert.equal(moved?.updatedBy, users.agentA);
  assert.equal(devices.rows.length, 6, 'moved, not duplicated');
  await push.registerPushDevice(auth('agentB'), { token: tok('agentB'), platform: 'android' }); // back to agentB
  // Signing out removes only your own device
  assert.equal(await push.unregisterPushDevice(auth('owner'), tok('agentA')), false);
  assert.equal(await push.unregisterPushDevice(auth('owner'), ''), false);
  await assert.rejects(push.registerPushDevice(auth('owner'), { token: 'short', platform: 'android' }));
  await assert.rejects(push.registerPushDevice(auth('owner'), { token: tok('x'), platform: 'windows' }));
  assert.equal(devices.rows.length, 6);
});

const chat = { id: 'conv-1', assignedToId: null as string | null, contact: { name: 'Push Customer', waId: '971500000001' } };

test('a customer message on an unassigned chat notifies every active teammate, once', async () => {
  await push.pushCustomerMessage(ws, chat, { id: 'msg-1', type: 'text', body: 'Do you have  265/65R17?' });
  const got = await take(5);
  assert.deepEqual(got.map((s) => s.token).sort(), ['owner', 'supervisor', 'agentA', 'agentB', 'collab'].map(tok).sort(), 'active teammates only (not the deactivated one)');
  for (const s of got) {
    assert.equal(s.title, 'Push Customer');
    assert.equal(s.body, 'Do you have 265/65R17?');
    assert.deepEqual(s.data, { conversationId: chat.id, kind: 'message' });
    assert.equal(s.channel, 'messages'); // the app's "Messages" channel (high importance: heads-up)
    assert.equal(s.tag, chat.id); // one notification per chat on Android
    assert.equal(s.collapseId, chat.id);
    assert.equal(s.threadId, chat.id); // grouped per chat on iOS
  }
  // The same message again (e.g. a retried webhook) notifies nobody
  await push.pushCustomerMessage(ws, chat, { id: 'msg-1', type: 'text', body: 'Do you have 265/65R17?' });
  assert.equal((await take(0, 100)).length, 0);
});

test('on an assigned chat, customer messages reach the assignee, collaborators, admins and supervisors only', async () => {
  collaborators.rows.push({ conversationId: chat.id, userId: users.collab });
  const assignedChat = { ...chat, assignedToId: 'm-agentA', contact: { name: null, waId: '971500000001' } };
  assert.deepEqual((await push.customerMessageRecipients(ws, assignedChat)).sort(), [users.owner, users.supervisor, users.agentA, users.collab].sort());
  await push.pushCustomerMessage(ws, assignedChat, { id: 'msg-2', type: 'image', body: '[image]' });
  const got = await take(4);
  assert.deepEqual(got.map((s) => s.token).sort(), ['owner', 'supervisor', 'agentA', 'collab'].map(tok).sort(), "not agentB: someone else's chat");
  assert.equal(got[0].title, '+971500000001', 'no name: the number');
  assert.equal(got[0].body, '📷 Photo');
  // An assignee who was deactivated gets nothing; the others still do
  assert.deepEqual((await push.customerMessageRecipients(ws, { ...chat, assignedToId: 'm-inactive' })).sort(), [users.owner, users.supervisor, users.collab].sort());
});

test('every message type has a WhatsApp-style preview', () => {
  const cases: [string, string, string | null, string][] = [
    ['text', 'Hello\n  there', null, 'Hello there'],
    ['button', 'Yes, interested', null, 'Yes, interested'],
    ['interactive', 'Book a fitting', null, 'Book a fitting'],
    ['image', '[image]', null, '📷 Photo'],
    ['image', 'front tyre', null, '📷 front tyre'],
    ['video', '[video]', null, '🎥 Video'],
    ['voice', '[audio]', null, '🎤 Voice message'],
    ['audio', '[audio]', null, '🎵 Audio'],
    ['sticker', '[sticker]', null, '🙂 Sticker'],
    ['document', '[document]', 'invoice.pdf', '📄 invoice.pdf'],
    ['document', '[document]', null, '📄 Document'],
    ['location', '[location]', null, '📍 Location'],
    ['contacts', '[contacts]', null, '👤 Contact'],
    ['order', '[order]', null, 'New message'],
    ['unsupported', '[unsupported]', null, 'New message'],
  ];
  for (const [type, body, mediaName, expected] of cases) assert.equal(push.pushPreview({ type, body, mediaName }), expected, type);
});

test("every push carries the app icon number (the unread total), so it's right while the app is closed", async () => {
  unreadSum = 79;
  await push.pushCustomerMessage(ws, chat, { id: 'msg-badge', type: 'text', body: 'Any 4x4 tyres?' });
  const got = await take(5);
  assert.equal(got.length, 5);
  for (const s of got) {
    assert.equal(s.iosBadge, 79, 'iPhone: the red number on the icon');
    assert.equal(s.androidCount, 79, 'Android launchers that show a number');
  }
  // The total can't be read (e.g. a database hiccup): the push still goes out, just without a number
  unreadSum = new Error('database unavailable');
  await push.pushToUsers(ws, [users.agentA], { title: 'Chat assigned to you', body: 'x', conversationId: chat.id, kind: 'assigned', collapseKey: 'assigned:badge' }, 'assign:badge');
  const fallback = await take(1);
  assert.deepEqual(fallback.map((s) => s.token), [tok('agentA')]);
  assert.equal(fallback[0].iosBadge, undefined);
  assert.equal(fallback[0].androidCount, undefined);
  unreadSum = 7;
});

test('assignment and @mention notices reach only that person; members of other workspaces never', async () => {
  await push.pushToUsers(ws, [users.agentA], { title: 'Chat assigned to you', body: 'Push Customer', conversationId: chat.id, kind: 'assigned', collapseKey: `assigned:${chat.id}` }, 'assign:1');
  const assigned = await take(1);
  assert.deepEqual(assigned.map((s) => s.token), [tok('agentA')]);
  assert.deepEqual(assigned[0].data, { conversationId: chat.id, kind: 'assigned' });

  await push.pushToUsers(ws, [users.agentB, 'u-elsewhere'], { title: 'Push owner mentioned you in a note', body: 'please call', conversationId: chat.id, kind: 'mention', collapseKey: 'mention:1' }, 'mention:1');
  const mentioned = await take(1);
  assert.deepEqual(mentioned.map((s) => s.token), [tok('agentB')]);
  assert.equal(mentioned[0].data.kind, 'mention');
});

test('a token Firebase reports as gone is forgotten; a failed send keeps the phone and never throws', async () => {
  await devices.create({ data: { token: GONE, userId: users.owner, workspaceId: ws, platform: 'android' } });
  await devices.create({ data: { token: BROKEN, userId: users.owner, workspaceId: ws, platform: 'android' } });
  await push.pushToUsers(ws, [users.owner], { title: 't', body: 'b', conversationId: chat.id, kind: 'message', collapseKey: chat.id }, 'gone:1');
  assert.deepEqual((await take(1)).map((s) => s.token), [tok('owner')], 'the working phone still gets it');
  assert.equal(await devices.findUnique({ where: { token: GONE } }), null);
  assert.ok(await devices.findUnique({ where: { token: BROKEN } }), 'an outage is not a reason to forget the phone');
  assert.ok(await devices.findUnique({ where: { token: tok('owner') } }), 'the working token stays');
});

test('signing out stops notifications to that phone', async () => {
  assert.equal(await push.unregisterPushDevice(auth('agentB'), tok('agentB')), true);
  await push.pushToUsers(ws, [users.agentB], { title: 't', body: 'b', conversationId: chat.id, kind: 'message', collapseKey: chat.id }, 'after-signout:1');
  assert.equal((await take(0, 100)).length, 0);
});
