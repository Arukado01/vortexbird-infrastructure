// Real PostgreSQL SQL/view integration through embedded PGlite; no API, sockets,
// concurrent sessions, external services, or end-to-end guarantees are exercised.
// node tests/PostgresProjectionChecks.cjs <migration-schema.sql> <report.json>
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const { insert: insertFixture } = require('./sql-fixtures.cjs');
const results = [];
let db;
let engine;
let schemaSha256;
async function check(name, action) {
  try { await action(); results.push({ name, status: 'passed' }); }
  catch (error) { results.push({ name, status: 'failed', error: error.message }); }
}
const insert = (table, values = {}) => insertFixture(db, table, values);
async function rows(sql, params = []) { return (await db.query(sql, params)).rows; }
function numbers(row, keys) { return Object.fromEntries(keys.map(key => [key, row[key] === null ? null : Number(row[key])])); }

(async () => {
  assert.ok(process.argv[2] && process.argv[3], 'Usage: node PostgresProjectionChecks.cjs <migration-schema.sql> <report.json>');
  const schema = fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '');
  schemaSha256 = crypto.createHash('sha256').update(schema).digest('hex');
  db = await PGlite.create();
  engine = (await rows('SELECT version() AS version'))[0].version;
  await db.exec(schema);
  // Deliberately non-UTC session: the reporting migration must choose UTC itself.
  await db.exec("SET TIME ZONE 'America/Bogota'");
  const partnerA = await insert('Partners', { Code: 'qa-a' });
  const partnerB = await insert('Partners', { Code: 'qa-b' });
  const channelA1 = await insert('Channels', { PartnerId: partnerA.Id, Code: 'web' });
  const channelA2 = await insert('Channels', { PartnerId: partnerA.Id, Code: 'app' });
  const channelB = await insert('Channels', { PartnerId: partnerB.Id, Code: 'web' });
  const stock = await insert('Stocks', { PartnerId: partnerA.Id, ChannelId: channelA1.Id, StoreId: 'STORE', Sku: 'ONE', OnHand: 10, Reserved: 3 });
  await insert('Stocks', { PartnerId: partnerA.Id, ChannelId: channelA1.Id, StoreId: 'STORE', Sku: 'TWO', OnHand: 5, Reserved: 2 });
  await insert('Stocks', { PartnerId: partnerA.Id, ChannelId: channelA2.Id, StoreId: 'STORE', Sku: 'ONE', OnHand: 20, Reserved: 1 });
  await insert('Stocks', { PartnerId: partnerB.Id, ChannelId: channelB.Id, StoreId: 'STORE', Sku: 'ONE', OnHand: 100, Reserved: 40 });
  const orders = [];
  for (const [partner, channel, total, status, created] of [
    [partnerA, channelA1, 100.25, 'confirmed', '2026-11-13T00:05:00Z'],
    [partnerA, channelA1, 25.50, 'cancelled', '2026-11-13T23:55:00Z'],
    [partnerA, channelA1, 10, 'confirmed', '2026-11-12T23:59:00Z'],
    [partnerA, channelA2, 250, 'confirmed', '2026-11-13T00:05:00Z'],
    [partnerB, channelB, 900, 'pending', '2026-11-13T00:05:00Z']
  ]) orders.push(await insert('Orders', { PartnerId: partner.Id, ChannelId: channel.Id, Total: total, Status: status, CreatedAt: created }));

  await check('Inventory view separates partner and channel with exact available sums', async () => {
    const data = await rows('SELECT * FROM vw_inventory_summary ORDER BY "PartnerId", "ChannelId"');
    assert.equal(data.length, 3);
    for (const [partner, channel, expected] of [[partnerA, channelA1, [2,15,5,10]], [partnerA, channelA2, [1,20,1,19]], [partnerB, channelB, [1,100,40,60]]]) {
      const row = data.find(x => x.PartnerId === partner.Id && x.ChannelId === channel.Id);
      assert.ok(row);
      assert.deepEqual(Object.values(numbers(row, ['skus','on_hand','reserved','available'])), expected);
    }
  });
  await check('Order metrics use UTC days despite a non-UTC database session', async () => {
    const data = await rows('SELECT day::text AS day, orders, gross_total FROM vw_dashboard_order_metrics WHERE "PartnerId"=$1 AND "ChannelId"=$2 ORDER BY day', [partnerA.Id, channelA1.Id]);
    assert.deepEqual(data.map(x => ({ day: x.day, ...numbers(x, ['orders','gross_total']) })), [
      { day: '2026-11-12', orders: 1, gross_total: 10 }, { day: '2026-11-13', orders: 2, gross_total: 125.75 }
    ]);
  });
  await check('Order metrics keep other channels and tenants separate', async () => {
    for (const [partner, channel, total] of [[partnerA, channelA2, 250], [partnerB, channelB, 900]]) {
      const data = await rows('SELECT orders, gross_total FROM vw_dashboard_order_metrics WHERE "PartnerId"=$1 AND "ChannelId"=$2', [partner.Id, channel.Id]);
      assert.equal(data.length, 1);
      assert.deepEqual(numbers(data[0], ['orders','gross_total']), { orders: 1, gross_total: total });
    }
  });
  await check('Status distribution preserves tenant/channel/state dimensions', async () => {
    const data = await rows('SELECT "Status", orders FROM vw_order_status_distribution WHERE "PartnerId"=$1 AND "ChannelId"=$2 ORDER BY "Status"', [partnerA.Id, channelA1.Id]);
    assert.deepEqual(data.map(x => [x.Status, Number(x.orders)]), [['cancelled', 1], ['confirmed', 2]]);
    assert.equal((await rows('SELECT count(*)::int AS count FROM vw_order_status_distribution'))[0].count, 4);
  });
  for (const [order, amount, status] of [[orders[0], 100.25, 'approved'], [orders[1], 25.5, 'rejected'], [orders[2], 10, 'approved'], [orders[4], 900, 'approved']])
    await insert('Payments', { OrderId: order.Id, PartnerId: order.PartnerId, Amount: amount, Status: status, Reference: crypto.randomUUID() });
  await check('Payment view aggregates exact amounts by tenant and status', async () => {
    const data = await rows('SELECT "Status", transactions, amount FROM vw_payment_summary WHERE "PartnerId"=$1 ORDER BY "Status"', [partnerA.Id]);
    assert.deepEqual(data.map(x => [x.Status, Number(x.transactions), Number(x.amount)]), [['approved',2,110.25],['rejected',1,25.5]]);
    const other = await rows('SELECT transactions, amount FROM vw_payment_summary WHERE "PartnerId"=$1', [partnerB.Id]);
    assert.deepEqual(numbers(other[0], ['transactions','amount']), { transactions: 1, amount: 900 });
  });
  for (const [partner, module, result] of [[partnerA.Id,'orders','success'],[partnerA.Id,'orders','success'],[partnerA.Id,'orders','denied'],[partnerB.Id,'orders','success'],[null,'administration','success']])
    await insert('ActivityLogs', { PartnerId: partner, Module: module, Result: result });
  await check('Audit view preserves result/tenant groups and explicit global rows', async () => {
    const data = await rows('SELECT "Result", actions FROM vw_partner_activity WHERE "PartnerId"=$1 ORDER BY "Result"', [partnerA.Id]);
    assert.deepEqual(data.map(x => [x.Result, Number(x.actions)]), [['denied',1],['success',2]]);
    assert.equal(Number((await rows('SELECT actions FROM vw_partner_activity WHERE "PartnerId" IS NULL'))[0].actions), 1);
    assert.equal(Number((await rows('SELECT actions FROM vw_partner_activity WHERE "PartnerId"=$1', [partnerB.Id]))[0].actions), 1);
  });
  const integration = await insert('Integrations', { System: 'ERP', Status: 'enabled' });
  const emptyIntegration = await insert('Integrations', { System: 'WMS', Status: 'disabled' });
  await insert('IntegrationExecutions', { IntegrationId: integration.Id, DurationMs: 10 });
  await insert('IntegrationExecutions', { IntegrationId: integration.Id, DurationMs: 30 });
  await check('Integration health reports exact mean and zero-execution integrations', async () => {
    const data = await rows('SELECT * FROM vw_integration_health');
    assert.equal(data.length, 2);
    assert.deepEqual(numbers(data.find(x => x.Id === integration.Id), ['executions','average_duration_ms']), { executions: 2, average_duration_ms: 20 });
    assert.deepEqual(numbers(data.find(x => x.Id === emptyIntegration.Id), ['executions','average_duration_ms']), { executions: 0, average_duration_ms: null });
  });
  await check('Inventory projection reflects committed changes without a separate refresh', async () => {
    await db.transaction(tx => tx.query('UPDATE "Stocks" SET "Reserved"=4 WHERE "Id"=$1', [stock.Id]));
    const data = await rows('SELECT reserved, available FROM vw_inventory_summary WHERE "PartnerId"=$1 AND "ChannelId"=$2', [partnerA.Id, channelA1.Id]);
    assert.deepEqual(numbers(data[0], ['reserved','available']), { reserved: 6, available: 9 });
  });
  await check('Rolled-back order changes do not survive in reporting views', async () => {
    const failure = new Error('Deliberate test rollback');
    await assert.rejects(db.transaction(async tx => { await tx.query('UPDATE "Orders" SET "Total"=9999 WHERE "Id"=$1', [orders[0].Id]); throw failure; }), error => error === failure);
    const data = await rows("SELECT gross_total FROM vw_dashboard_order_metrics WHERE \"PartnerId\"=$1 AND \"ChannelId\"=$2 AND day='2026-11-13'", [partnerA.Id, channelA1.Id]);
    assert.equal(Number(data[0].gross_total), 125.75);
  });
})().catch(error => results.push({ name: 'Fixture/schema setup', status: 'failed', error: error.message })).finally(async () => {
  if (db) await db.close();
  const report = { measuredAt: new Date().toISOString(), transport: 'Embedded PostgreSQL via PGlite JavaScript API', engine, schemaSha256,
    passed: results.filter(x => x.status === 'passed').length, failed: results.filter(x => x.status === 'failed').length, results,
    limitations: ['Production migrations and reporting views with real fixtures; not API or handler integration', 'Single embedded SQL session; no concurrent locks or distributed quota proof', 'PostgreSQL WASM version differs from deployed PostgreSQL17; no external services or E2E run'] };
  if (process.argv[3]) { const output = path.resolve(process.argv[3]); fs.mkdirSync(path.dirname(output), { recursive: true }); fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n'); }
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = report.failed ? 1 : 0;
});
