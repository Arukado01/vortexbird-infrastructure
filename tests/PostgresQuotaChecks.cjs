// Tests the exact production upsert SQL + migrated constraints in one embedded
// PostgreSQL session. This is not a .NET/Npgsql or concurrent-lock integration test.
// node tests/PostgresQuotaChecks.cjs <schema.sql> <Infrastructure/Quotas.cs> <report.json>
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { PGlite } = require(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const results = [];
let db, engine, sourceHash, schemaHash;
async function check(name, action) {
  try { await action(); results.push({name,status:'passed'}); }
  catch(error) { results.push({name,status:'failed',error:error.message}); }
}
(async () => {
  assert.ok(process.argv[2] && process.argv[3] && process.argv[4], 'Expected schema.sql, Quotas.cs and report.json paths');
  const schema = fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '');
  const source = fs.readFileSync(process.argv[3], 'utf8');
  schemaHash = crypto.createHash('sha256').update(schema).digest('hex');
  sourceHash = crypto.createHash('sha256').update(source).digest('hex');
  const match = source.match(/INSERT INTO "QuotaCounters"[\s\S]+?\n\s+"Minute" = EXCLUDED\."Minute"/);
  assert.ok(match, 'Production quota upsert SQL not found; update the extractor if its location changes');
  const sql = match[0].replace('{partnerId}','$1').replace('{budget.Key}','$2').replace('{minute}','$3');
  assert.ok(!/[{}]/.test(sql), 'Unexpected unbound production SQL interpolation');
  db = await PGlite.create();
  engine = (await db.query('SELECT version() AS engine')).rows[0].engine;
  await db.exec(schema);
  const tenant = crypto.randomUUID();
  const other = crypto.randomUUID();
  for (const [id, code] of [[tenant,'quota-one'],[other,'quota-two']])
    await db.query('INSERT INTO "Partners" ("Id","Name","Code","Enabled","RequestsPerMinute") VALUES ($1,$2,$2,true,120)',[id,code]);
  const upsert = (connection, key, minute, partner = tenant) => connection.query(sql,[partner,key,minute]);
  const counter = async (key = 'partner', partner = tenant) => (await db.query('SELECT "Minute", "Count" FROM "QuotaCounters" WHERE "PartnerId"=$1 AND "BudgetKey"=$2',[partner,key])).rows[0];
  await check('Production upsert increments exactly once within the same window',async()=>{
    await upsert(db,'partner',100); await upsert(db,'partner',100);
    const row = await counter(); assert.equal(Number(row.Minute),100); assert.equal(row.Count,2);
  });
  await check('Next minute replaces the previous count without accumulating rows',async()=>{
    await upsert(db,'partner',101);
    const row = await counter(); assert.equal(Number(row.Minute),101); assert.equal(row.Count,1);
    assert.equal((await db.query('SELECT count(*)::int AS count FROM "QuotaCounters"')).rows[0].count,1);
  });
  await check('Identical budget keys remain isolated across tenants',async()=>{
    await upsert(db,'partner',101,other); await upsert(db,'partner',101,other);
    assert.equal((await counter()).Count,1); assert.equal((await counter('partner',other)).Count,2);
  });
  const channelA = 'channel:'+crypto.randomUUID().replaceAll('-','');
  const channelB = 'channel:'+crypto.randomUUID().replaceAll('-','');
  await check('Channels have independent persisted budgets within a tenant',async()=>{
    await upsert(db,channelA,101); await upsert(db,channelA,101); await upsert(db,channelB,101);
    assert.equal((await counter(channelA)).Count,2); assert.equal((await counter(channelB)).Count,1);
  });
  await check('Transaction failure rolls back every prior budget increment',async()=>{
    await assert.rejects(db.transaction(async tx=>{
      await upsert(tx,'partner',101); await upsert(tx,channelA,101);
      await tx.query('UPDATE "QuotaCounters" SET "Count"=-1 WHERE "PartnerId"=$1 AND "BudgetKey"=$2',[tenant,channelB]);
    }),error=>error.code==='23514');
    assert.equal((await counter()).Count,1); assert.equal((await counter(channelA)).Count,2); assert.equal((await counter(channelB)).Count,1);
  });
  await check('Quota counters reject nonexistent tenants',async()=>{
    await assert.rejects(upsert(db,'partner',101,crypto.randomUUID()),error=>error.code==='23503');
  });
  await check('PostgreSQL clock and transaction advisory-lock expressions execute',async()=>{
    await db.transaction(async tx=>{
      await tx.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',['quota:'+tenant.replaceAll('-','')]);
      const value=(await tx.query('SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS value')).rows[0].value;
      assert.ok(Number(value)>0);
    });
  });
})().catch(error=>results.push({name:'Schema/source setup',status:'failed',error:error.message})).finally(async()=>{
  if(db)await db.close();
  const report={measuredAt:new Date().toISOString(),engine,schemaSha256:schemaHash,productionSourceSha256:sourceHash,passed:results.filter(x=>x.status==='passed').length,failed:results.filter(x=>x.status==='failed').length,results,
    limitations:['Single embedded PostgreSQL session, not Npgsql application execution','Exact production upsert plus schema/rollback tested; request budget selection and scope parser tested separately in .NET','No multi-replica concurrency, lock contention, failover or E2E measurement']};
  if(process.argv[4]){const output=path.resolve(process.argv[4]);fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');}
  console.log(JSON.stringify(report,null,2));process.exitCode=report.failed?1:0;
});
