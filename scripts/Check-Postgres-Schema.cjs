// Supplemental SQL engine validation. This does not test networking, EF runtime
// queries, multiple DB sessions, locking, failover, load, or the target PG17 build.
// Usage: PGLITE_MODULE=<module directory> node Check-Postgres-Schema.cjs <schema.sql> <report.json>
const fs = require('node:fs');
const crypto = require('node:crypto');
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const results = [];
let db;
const check = async (name, test) => {
  try { await test(); results.push({ name, status: 'passed' }); }
  catch (e) { results.push({ name, status: 'failed', error: e.message, sqlState: e.code }); }
};
const mustReject = async (operation, code) => {
  let caught;
  try { await operation(); } catch (e) { caught = e; }
  if (!caught || caught.code !== code) throw new Error(`Expected SQLSTATE ${code}; got ${caught?.code || 'successful query'}`);
};
async function insert(table, overrides = {}) {
  const cols = (await db.query('SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY ordinal_position', ['public', table])).rows;
  const data = {};
  for (const c of cols) {
    if (c.is_nullable === 'YES') data[c.column_name] = null;
    else if (c.data_type === 'uuid') data[c.column_name] = crypto.randomUUID();
    else if (c.data_type === 'boolean') data[c.column_name] = true;
    else if (['integer','bigint','double precision','numeric'].includes(c.data_type)) data[c.column_name] = c.column_name === 'RequestsPerMinute' ? 120 : 1;
    else if (c.data_type.includes('timestamp')) data[c.column_name] = new Date().toISOString();
    else data[c.column_name] = 'validation';
  }
  Object.assign(data, overrides);
  const keys = Object.keys(data);
  await db.query(`INSERT INTO "${table}" (${keys.map(k => `"${k}"`).join(',')}) VALUES (${keys.map((_, i) => `$${i+1}`).join(',')})`, keys.map(k => data[k]));
  return data;
}
(async () => {
  db = await PGlite.create();
  const engine = (await db.query('select version()')).rows[0].version;
  const sql = fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '');
  await check('EF PostgreSQL generated schema executes', () => db.exec(sql));
  if (results[0].status !== 'passed') {
    fs.writeFileSync(process.argv[3],JSON.stringify({generatedAt:new Date().toISOString(),engine,source:process.argv[2],passed:0,failed:1,results},null,2)+'\n');
    throw new Error('Schema creation failed: '+results[0].error);
  }
  if(sql.includes('__EFMigrationsHistory')) {
    await check('Versioned migration script is idempotent',()=>db.exec(sql));
    await check('Six reporting views are queryable',async()=>{
      const views=['vw_dashboard_order_metrics','vw_inventory_summary','vw_payment_summary','vw_partner_activity','vw_integration_health','vw_order_status_distribution'];
      for(const view of views)await db.query('SELECT * FROM '+view+' LIMIT 1');
    });
  }
  const p = await insert('Partners', { Code: 'test-partner' });
  const p2 = await insert('Partners', { Code: 'another-partner' });
  const c = await insert('Channels', { PartnerId: p.Id, Code: 'web' });
  const s = await insert('Stocks', { PartnerId:p.Id, ChannelId:c.Id, Sku:'TEST', StoreId:'STORE', OnHand:5, Reserved:1 });
  await check('Stock permits valid reservation', async()=>{
    await db.query('UPDATE "Stocks" SET "Reserved"=4 WHERE "Id"=$1',[s.Id]);
    if ((await db.query('SELECT "Reserved" FROM "Stocks" WHERE "Id"=$1',[s.Id])).rows[0].Reserved!==4) throw new Error('Reservation not saved');
  });
  await check('Stock rejects oversell via CHECK constraint', ()=>mustReject(()=>db.query('UPDATE "Stocks" SET "Reserved"=6 WHERE "Id"=$1',[s.Id]),'23514'));
  await check('Stock rejects negative inventory', ()=>mustReject(()=>db.query('UPDATE "Stocks" SET "OnHand"=-1 WHERE "Id"=$1',[s.Id]),'23514'));
  await check('Stock rejects negative reservation', ()=>mustReject(()=>db.query('UPDATE "Stocks" SET "Reserved"=-1 WHERE "Id"=$1',[s.Id]),'23514'));
  await check('Stock rejects channel belonging to another partner', ()=>mustReject(()=>insert('Stocks',{PartnerId:p2.Id,ChannelId:c.Id}), '23503'));
  await check('Price rejects channel belonging to another partner', ()=>mustReject(()=>insert('Prices',{PartnerId:p2.Id,ChannelId:c.Id}), '23503'));
  await check('Order rejects channel belonging to another partner', ()=>mustReject(()=>insert('Orders',{PartnerId:p2.Id,ChannelId:c.Id}), '23503'));
  await insert('Prices',{PartnerId:p.Id,ChannelId:c.Id,Sku:'TEST',CustomerId:null});
  await check('Default price duplicate NULL customer is rejected', ()=>mustReject(()=>insert('Prices',{PartnerId:p.Id,ChannelId:c.Id,Sku:'TEST',CustomerId:null}), '23505'));
  await insert('IdempotencyRecords',{PartnerId:p.Id,Key:'request-1'});
  await check('Same partner and idempotency key is unique', ()=>mustReject(()=>insert('IdempotencyRecords',{PartnerId:p.Id,Key:'request-1'}), '23505'));
  await check('Different partners may reuse idempotency key', ()=>insert('IdempotencyRecords',{PartnerId:p2.Id,Key:'request-1'}));
  const msg = await insert('ProcessedMessages',{Consumer:'consumer-a'});
  await check('Consumer rejects duplicate message', ()=>mustReject(()=>insert('ProcessedMessages',{Id:msg.Id,Consumer:'consumer-a'}), '23505'));
  await check('Another consumer may process the same event', ()=>insert('ProcessedMessages',{Id:msg.Id,Consumer:'consumer-b'}));
  await check('Transaction rolls back stock change on failure', async()=>{
    const before=(await db.query('SELECT "Reserved" FROM "Stocks" WHERE "Id"=$1',[s.Id])).rows[0].Reserved;
    try { await db.transaction(async tx=>{await tx.query('UPDATE "Stocks" SET "Reserved"=0 WHERE "Id"=$1',[s.Id]);throw new Error('simulated workflow failure');}); } catch(e) { if(e.message!=='simulated workflow failure') throw e; }
    const after=(await db.query('SELECT "Reserved" FROM "Stocks" WHERE "Id"=$1',[s.Id])).rows[0].Reserved;
    if(before!==after) throw new Error('Rollback did not restore reservation');
  });
  const delivery=await insert('WebhookDeliveries');
  await check('Webhook event/subscription deduplicates delivery', ()=>mustReject(()=>insert('WebhookDeliveries',{SubscriptionId:delivery.SubscriptionId,EventId:delivery.EventId}), '23505'));
  const counts=(await db.query("select (select count(*)::int from information_schema.tables where table_schema='public' and table_type='BASE TABLE') as tables, (select count(*)::int from pg_indexes where schemaname='public') as indexes")).rows[0];
  const report={generatedAt:new Date().toISOString(),engine,source:process.argv[2],schemaSha256:crypto.createHash('sha256').update(sql).digest('hex'),...counts,passed:results.filter(r=>r.status==='passed').length,failed:results.filter(r=>r.status==='failed').length,results,limitations:['Embedded PostgreSQL18.6 WASM, not target PostgreSQL17 server','Single process; concurrent sessions/locks/failover not validated','No external PostgreSQL deployment or full API E2E','Schema validation does not prove 99.9% availability or p95 SLO']};
  fs.writeFileSync(process.argv[3],JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  if(report.failed) process.exitCode=1;
})().catch(e=>{console.error(e.message);process.exitCode=1;}).finally(async()=>{if(db)await db.close();});
