// Push stays off until Firebase is configured: nothing is stored and nothing is sent (no service account in the env).
// Isolated: no database (dead address, in-memory device table) and no Firebase.
//   npx tsx --test test/pushOff.test.ts
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fakeTable } from './pushFakes.js';

test('without a Firebase service account: push is off, devices are not stored, sends do nothing', async () => {
  // Empty, not deleted: loading the server's .env must not switch push back on during this test
  process.env.FIREBASE_SERVICE_ACCOUNT = '';
  process.env.FIREBASE_SERVICE_ACCOUNT_FILE = '';
  process.env.DATABASE_URL = 'mysql://isolated:none@127.0.0.1:1/push_test_isolated';
  const { prisma } = await import('../src/prisma.js');
  const devices = fakeTable([], { autoId: true });
  Object.defineProperty(prisma, 'pushDevice', { value: devices, configurable: true });
  const push = await import('../src/services/push.js');
  const { getApps } = await import('firebase-admin/app');

  assert.equal(push.pushConfigured(), false);
  const token = 'fcm-off-000000000000000000';
  assert.equal(await push.registerPushDevice({ userId: 'u-off', workspaceId: 'w-off' }, { token, platform: 'android' }), false);
  assert.equal(devices.rows.length, 0);
  await push.pushToUsers('w-off', ['u-off'], { title: 't', body: 'b', conversationId: 'c', kind: 'message', collapseKey: 'c' }, 'k'); // no throw, no request
  assert.equal(getApps().length, 0, 'Firebase never started');
});
