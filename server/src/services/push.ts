import { readFileSync } from 'node:fs';
import { cert, getApps, initializeApp } from 'firebase-admin/app';
import { getMessaging, type Message, type Messaging } from 'firebase-admin/messaging';
import { z } from 'zod';
import type { AuthPayload } from '../auth.js';
import { env } from '../env.js';
import { prisma } from '../prisma.js';
import { unreadTotal } from './activity.js';
import { isSupervisorOrAbove } from './roles.js';
import { parse } from './validate.js';

// Push notifications to the mobile app through Firebase Cloud Messaging (Firebase Admin SDK). They reach a phone when
// the app is in the background or closed; in the foreground the app shows the same events from its live Socket.IO
// connection (and shows a push itself only while that connection is down, so nothing is shown twice).
//
// Off unless a Firebase service account is configured (env.firebaseServiceAccount / ...File). The account's private
// key stays on this server; the app only registers its device token.

type ServiceAccount = { project_id: string; client_email: string; private_key: string };

let account: ServiceAccount | null | undefined; // undefined = not read yet
let configError: string | null = null;

function loadAccount(): ServiceAccount | null {
  if (account !== undefined) return account;
  account = null;
  try {
    const raw = env.firebaseServiceAccount || (env.firebaseServiceAccountFile ? readFileSync(env.firebaseServiceAccountFile, 'utf8') : '');
    if (!raw) return null;
    const j = JSON.parse(raw);
    if (!j.project_id || !j.client_email || !j.private_key) throw new Error('missing project_id, client_email or private_key');
    account = { project_id: j.project_id, client_email: j.client_email, private_key: j.private_key };
  } catch (err) {
    configError = (err as Error).message;
    console.error('[push] Firebase service account unusable, push is off:', configError);
  }
  return account;
}

/** Whether this server can send push notifications (the app only registers its device when it can) */
export const pushConfigured = () => loadAccount() !== null;

// --- Firebase Admin: its own named app (signs in to Google with the service account and caches the access token)

type Sender = Pick<Messaging, 'send'>;
let sender: Sender | null | undefined; // undefined = not set up yet

function getSender(): Sender | null {
  if (sender !== undefined) return sender;
  const sa = loadAccount();
  if (!sa) return null;
  const name = 'push';
  const app =
    getApps().find((a) => a.name === name) ??
    initializeApp({ credential: cert({ projectId: sa.project_id, clientEmail: sa.client_email, privateKey: sa.private_key }), projectId: sa.project_id }, name);
  sender = getMessaging(app);
  return sender;
}

/** Tests only: sends go to this fake instead of Firebase (nothing leaves the process) */
export function setPushSenderForTests(fake: Sender) {
  sender = fake;
}

// --- Device registration (the signed-in person's phone, for the workspace they're signed in to)

const registerSchema = z.object({
  token: z.string().trim().min(20, 'Invalid device token').max(512, 'Invalid device token'),
  platform: z.enum(['android', 'ios']),
});

/** Saves this phone for the signed-in person. A token already registered moves to them (someone else signed in on
 * that phone). Returns false, storing nothing, while push isn't configured on this server. */
export async function registerPushDevice(auth: AuthPayload, input: unknown) {
  const { token, platform } = parse(registerSchema, input);
  if (!pushConfigured()) return false;
  await prisma.pushDevice.upsert({
    where: { token },
    create: { token, platform, userId: auth.userId, workspaceId: auth.workspaceId, createdBy: auth.userId, updatedBy: auth.userId },
    update: { platform, userId: auth.userId, workspaceId: auth.workspaceId, updatedBy: auth.userId },
  });
  return true;
}

/** Signing out on a phone: it gets no more notifications for this person */
export async function unregisterPushDevice(auth: AuthPayload, token: unknown) {
  if (typeof token !== 'string' || !token) return false;
  const { count } = await prisma.pushDevice.deleteMany({ where: { token, userId: auth.userId } });
  return count > 0;
}

// --- Sending

export type PushNotice = {
  title: string;
  body: string;
  conversationId: string;
  /** message | assigned | mention */
  kind: string;
  /** Collapses repeats on the phone (e.g. one notification per chat, the newest replacing older ones) */
  collapseKey: string;
};

// Recently sent (notice key + user), so the same event never notifies anyone twice (e.g. a webhook delivered twice)
const sentRecently = new Map<string, number>();
const SENT_TTL_MS = 10 * 60_000;

function alreadySent(key: string) {
  const now = Date.now();
  if (sentRecently.size > 5000) for (const [k, at] of sentRecently) if (now - at > SENT_TTL_MS) sentRecently.delete(k);
  const at = sentRecently.get(key);
  if (at && now - at < SENT_TTL_MS) return true;
  sentRecently.set(key, now);
  return false;
}

const truncate = (s: string, max: number) => (s.length > max ? `${s.slice(0, max - 1)}…` : s);

// Firebase's answers that mean the app was uninstalled or the token replaced: forget that phone
const GONE_CODES = new Set(['messaging/registration-token-not-registered', 'messaging/invalid-registration-token']);

/** The number on the app's icon (like WhatsApp's): unread customer messages, the same total as the app's Chats tab.
 * Sent with every push so it stays right while the app is closed. Best effort: without it the push still goes out. */
async function iconBadge(workspaceId: string) {
  try {
    return await unreadTotal(workspaceId);
  } catch (err) {
    console.error('[push] unread total unavailable, sending without the icon number:', (err as Error).message);
    return undefined;
  }
}

async function sendOne(send: Sender, token: string, n: PushNotice, badge?: number): Promise<'ok' | 'gone' | 'failed'> {
  const message: Message = {
    token,
    notification: { title: truncate(n.title, 100), body: truncate(n.body, 240) },
    // Strings only (FCM's rule); the app opens this chat when the notification is tapped
    data: { conversationId: n.conversationId, kind: n.kind },
    android: {
      priority: 'high',
      collapseKey: n.collapseKey,
      // notificationCount: the icon number on launchers that show one (Samsung, Xiaomi…)
      notification: { channelId: 'messages', tag: n.collapseKey, sound: 'default', ...(badge !== undefined ? { notificationCount: badge } : {}) },
    },
    apns: {
      headers: { 'apns-priority': '10', 'apns-collapse-id': n.collapseKey.slice(0, 64) },
      // badge: the red number on the iPhone's app icon
      payload: { aps: { sound: 'default', threadId: n.conversationId, ...(badge !== undefined ? { badge } : {}) } },
    },
  };
  try {
    await send.send(message);
    return 'ok';
  } catch (err) {
    const e = err as { code?: string; message?: string };
    if (GONE_CODES.has(e.code ?? '') || (e.code === 'messaging/invalid-argument' && /token/i.test(e.message ?? ''))) return 'gone';
    console.error('[push] FCM refused a notification:', e.code ?? '', e.message ?? '');
    return 'failed';
  }
}

/** Notifies these people's phones (active members of the workspace only). Never throws; does nothing while push
 * isn't configured. `key` identifies the event so it is sent at most once per person. */
export async function pushToUsers(workspaceId: string, userIds: Iterable<string>, notice: PushNotice, key: string) {
  try {
    const send = getSender();
    if (!send) return;
    const ids = [...new Set(userIds)].filter((id) => !alreadySent(`${key}:${id}`));
    if (!ids.length) return;
    const active = await prisma.member.findMany({ where: { workspaceId, active: true, userId: { in: ids } }, select: { userId: true } });
    const devices = await prisma.pushDevice.findMany({ where: { workspaceId, userId: { in: active.map((m) => m.userId) } }, select: { token: true } });
    if (!devices.length) return;
    const badge = await iconBadge(workspaceId);
    const results = await Promise.all(devices.map(async (d) => ({ token: d.token, r: await sendOne(send, d.token, notice, badge) })));
    const gone = results.filter((x) => x.r === 'gone').map((x) => x.token);
    if (gone.length) await prisma.pushDevice.deleteMany({ where: { token: { in: gone } } });
  } catch (err) {
    console.error('[push] notify failed:', (err as Error).message);
  }
}

/** Who is alerted about a customer's message: owners, admins and supervisors for every chat; for an unassigned chat
 * everyone (anyone may take it); otherwise also its assignee and collaborators */
export async function customerMessageRecipients(workspaceId: string, conversation: { id: string; assignedToId: string | null }) {
  const members = await prisma.member.findMany({ where: { workspaceId, active: true }, select: { id: true, userId: true, role: true } });
  if (!conversation.assignedToId) return members.map((m) => m.userId);
  const collaborators = await prisma.conversationCollaborator.findMany({ where: { conversationId: conversation.id }, select: { userId: true } });
  const ids = new Set(members.filter((m) => isSupervisorOrAbove(m.role)).map((m) => m.userId));
  const assignee = members.find((m) => m.id === conversation.assignedToId);
  if (assignee) ids.add(assignee.userId);
  for (const c of collaborators) ids.add(c.userId);
  return [...ids];
}

/** A customer's new WhatsApp message (saved from the webhook): the customer's name and a one-line preview */
export async function pushCustomerMessage(
  workspaceId: string,
  conversation: { id: string; assignedToId: string | null; contact: { name: string | null; waId: string } },
  message: { id: string; type: string; body: string; mediaName?: string | null },
) {
  if (!pushConfigured()) return;
  const title = conversation.contact.name?.trim() || `+${conversation.contact.waId}`;
  const body = pushPreview(message);
  const to = await customerMessageRecipients(workspaceId, conversation);
  await pushToUsers(workspaceId, to, { title, body, conversationId: conversation.id, kind: 'message', collapseKey: conversation.id }, `msg:${message.id}`);
}

/** One line for the notification, by message type (like WhatsApp's: an icon and a word for anything that isn't text) */
export function pushPreview(message: { type: string; body: string; mediaName?: string | null }) {
  const text = message.body.replace(/\s+/g, ' ').trim();
  const placeholder = /^\[[a-z_]+\]$/.test(text); // "[image]", "[location]"…: nothing the customer wrote
  const caption = placeholder ? '' : text;
  switch (message.type) {
    case 'image': return `📷 ${caption || 'Photo'}`;
    case 'video': return `🎥 ${caption || 'Video'}`;
    case 'voice': return '🎤 Voice message';
    case 'audio': return '🎵 Audio';
    case 'sticker': return '🙂 Sticker';
    case 'document': return `📄 ${message.mediaName || caption || 'Document'}`;
    case 'location': return '📍 Location';
    case 'contacts': return '👤 Contact';
    default: return caption || 'New message'; // text, button and list replies; anything new Meta sends
  }
}
