const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const { insert } = require('./sql-fixtures.cjs');

test('business acceptance requires persisted effects for the exact two orders', async t => {
  const backend = path.resolve(__dirname, '../../vortexbird-backend');
  const db = await PGlite.create();
  t.after(() => db.close());
  await db.exec(fs.readFileSync(path.join(backend, 'scripts/schema.sql'), 'utf8'));
  const partner = await insert(db, 'Partners');
  const channel = await insert(db, 'Channels', { PartnerId: partner.Id });
  const scope = { PartnerId: partner.Id, ChannelId: channel.Id };
  const rejected = await insert(db, 'Orders', scope);
  const approved = await insert(db, 'Orders', scope);
  const sql = fs.readFileSync(path.join(backend, 'tests/BusinessPersistence.sql'), 'utf8')
    .replaceAll(":'rejected'", '$1').replaceAll(":'approved'", '$2');
  const snapshot = async () => (await db.query(sql, [rejected.Id, approved.Id])).rows[0].json_build_object;
  assert.deepEqual(await snapshot(), { durableEvents: 0, released: false, committed: false, confirmedTransitions: 0 });

  const stock = await insert(db, 'Stocks', scope);
  for (const [order, status] of [[rejected, 'released'], [approved, 'committed']]) {
    await insert(db, 'InventoryReservations', { PartnerId: partner.Id, StockId: stock.Id, OrderId: order.Id, Status: status });
  }
  await insert(db, 'OrderHistories', { OrderId: approved.Id, Status: 'confirmed' });
  const completedAt = '2026-11-17T00:00:00Z';
  const consumer = 'integration-router-v1';
  const createEvent = (order, type) => insert(db, 'OutboxMessages', {
    PartnerId: partner.Id, Type: type, Payload: JSON.stringify({ orderId: order.Id }), Status: 'processed', ProcessedAt: completedAt
  });
  const events = [];
  for (const [order, type] of [[rejected,'order.created'], [rejected,'payment.rejected'], [approved,'order.created'], [approved,'payment.approved'], [approved,'order.confirmed']]) {
    const event = await createEvent(order, type);
    events.push(event);
    await insert(db, 'MessagingInbox', { PartnerId: partner.Id, EventId: event.Id, Consumer: consumer, Status: 'completed', CompletedAt: completedAt });
    await insert(db, 'ProcessedMessages', { Id: event.Id, Consumer: consumer });
  }
  assert.deepEqual(await snapshot(), { durableEvents: 5, released: true, committed: true, confirmedTransitions: 1 });
  await db.query('DELETE FROM "ProcessedMessages" WHERE "Id" = $1', [events[0].Id]);
  assert.equal((await snapshot()).durableEvents, 4);
  await createEvent(approved, 'order.confirmed');
  assert.equal((await snapshot()).durableEvents, 3);
  await db.query('UPDATE "InventoryReservations" SET "Status" = $1 WHERE "OrderId" = $2', ['active', rejected.Id]);
  assert.equal((await snapshot()).released, false);
});
