// Migrated payment constraints and SQL lease predicates, with real PostgreSQL
// fixtures. Does NOT execute C# settlement, workers, HTTP, or an external gateway.
// node tests/PostgresPaymentChecks.cjs <schema.sql> <report.json>
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const assert=require('node:assert/strict');
const {PGlite}=require(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const {insert:fixture}=require('./sql-fixtures.cjs');
const results=[];
let db,engine,schemaHash;
async function check(name,action){try{await action();results.push({name,status:'passed'});}catch(error){results.push({name,status:'failed',error:error.message});}}
const reject=(action,code)=>assert.rejects(action,error=>error.code===code);
(async()=>{
  assert.ok(process.argv[2]&&process.argv[3],'Expected schema.sql and report.json paths');
  const schema=fs.readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,'');
  schemaHash=crypto.createHash('sha256').update(schema).digest('hex');
  db=await PGlite.create();engine=(await db.query('SELECT version() AS engine')).rows[0].engine;
  await db.exec(schema);
  const insert=(table,row)=>fixture(db,table,row);
  const partnerA=await insert('Partners',{Code:'payment-a'});
  const partnerB=await insert('Partners',{Code:'payment-b'});
  const channelA=await insert('Channels',{PartnerId:partnerA.Id,Code:'web'});
  const channelA2=await insert('Channels',{PartnerId:partnerA.Id,Code:'app'});
  const channelB=await insert('Channels',{PartnerId:partnerB.Id,Code:'web'});
  const order=async(partner=partnerA,channel=channelA)=>insert('Orders',{PartnerId:partner.Id,ChannelId:channel.Id,Total:100,Currency:'COP'});
  const checkout=async(order,overrides={})=>insert('PaymentCheckouts',{OrderId:order.Id,PartnerId:order.PartnerId,ChannelId:order.ChannelId,ExpectedAmount:100,Currency:'COP',ExternalReference:crypto.randomUUID(),...overrides});
  const first=await order();await checkout(first);
  const second=await order(partnerB,channelB);await checkout(second);
  const canonicalKey=crypto.createHash('sha256').update('id:456;request-id:qa-1;ts:1794595200;').digest('hex').toUpperCase();
  const inbox=await insert('PaymentInbox',{NotificationKey:canonicalKey,ProviderPaymentId:'456',Status:'pending'});
  await check('Durable inbox rejects the same canonical notification key',()=>reject(()=>insert('PaymentInbox',{NotificationKey:canonicalKey,ProviderPaymentId:'456'}),'23505'));
  await check('Different authenticated deliveries may reference the same payment',()=>insert('PaymentInbox',{NotificationKey:crypto.createHash('sha256').update('id:456;request-id:qa-2;ts:1794595200;').digest('hex'),ProviderPaymentId:'456'}));
  await insert('PaymentReceipts',{ProviderPaymentId:'456',OrderId:first.Id});
  await check('Provider payment identity cannot be assigned to another order or tenant',()=>reject(()=>insert('PaymentReceipts',{ProviderPaymentId:'456',OrderId:second.Id}),'23505'));
  await check('Receipt requires a persisted checkout intent',()=>reject(()=>insert('PaymentReceipts',{ProviderPaymentId:'457',OrderId:crypto.randomUUID()}),'23503'));
  await check('Checkout cannot replace the order tenant',async()=>{const item=await order();await reject(()=>checkout(item,{PartnerId:partnerB.Id}),'23503');});
  await check('Checkout cannot replace the order channel within the same tenant',async()=>{const item=await order();await reject(()=>checkout(item,{ChannelId:channelA2.Id}),'23503');});
  await check('Checkout rejects zero or negative expected amount',async()=>{for(const amount of [0,-1]){const item=await order();await reject(()=>checkout(item,{ExpectedAmount:amount}),'23514');}});
  await check('Checkout accepts COP and rejects a mismatched currency',async()=>{const item=await order();await reject(()=>checkout(item,{Currency:'USD'}),'23514');});
  await check('One order cannot acquire a second checkout intent',()=>reject(()=>checkout(first),'23505'));
  const oldLease=crypto.randomUUID(),currentLease=crypto.randomUUID();
  await db.query('UPDATE "PaymentInbox" SET "LeaseId"=$1,"Status"=$2 WHERE "Id"=$3',[currentLease,'processing',inbox.Id]);
  await check('A stale inbox lease cannot complete a reclaimed notification',async()=>{
    const stale=await db.query('UPDATE "PaymentInbox" SET "Status"=$1 WHERE "Id"=$2 AND "LeaseId"=$3',['processed',inbox.Id,oldLease]);
    assert.equal(stale.affectedRows,0);
    assert.equal((await db.query('SELECT "Status" FROM "PaymentInbox" WHERE "Id"=$1',[inbox.Id])).rows[0].Status,'processing');
    const owner=await db.query('UPDATE "PaymentInbox" SET "Status"=$1 WHERE "Id"=$2 AND "LeaseId"=$3',['processed',inbox.Id,currentLease]);
    assert.equal(owner.affectedRows,1);
  });
  await db.query('UPDATE "PaymentCheckouts" SET "LeaseId"=$1,"State"=$2 WHERE "OrderId"=$3',[currentLease,'unknown',first.Id]);
  await check('A stale checkout lease cannot overwrite the current worker state',async()=>{
    const stale=await db.query('UPDATE "PaymentCheckouts" SET "State"=$1 WHERE "OrderId"=$2 AND "LeaseId"=$3',['pending',first.Id,oldLease]);
    assert.equal(stale.affectedRows,0);
    assert.equal((await db.query('SELECT "State" FROM "PaymentCheckouts" WHERE "OrderId"=$1',[first.Id])).rows[0].State,'unknown');
    const owner=await db.query('UPDATE "PaymentCheckouts" SET "State"=$1 WHERE "OrderId"=$2 AND "LeaseId"=$3',['pending',first.Id,currentLease]);
    assert.equal(owner.affectedRows,1);
  });
  await check('A receipt insert rolls back when a companion checkout update violates constraints',async()=>{
    await reject(()=>db.transaction(async tx=>{
      await tx.query('INSERT INTO "PaymentReceipts" ("ProviderPaymentId","OrderId","ProviderStatus","Disposition","UpdatedAt") VALUES ($1,$2,$3,$4,now())',['rollback-receipt',second.Id,'approved','observed']);
      await tx.query('UPDATE "PaymentCheckouts" SET "ExpectedAmount"=0 WHERE "OrderId"=$1',[second.Id]);
    }),'23514');
    assert.equal((await db.query('SELECT count(*)::int AS count FROM "PaymentReceipts" WHERE "ProviderPaymentId"=$1',['rollback-receipt'])).rows[0].count,0);
  });
})().catch(error=>results.push({name:'Schema/fixture setup',status:'failed',error:error.message})).finally(async()=>{
  if(db)await db.close();const report={measuredAt:new Date().toISOString(),engine,schemaSha256:schemaHash,passed:results.filter(x=>x.status==='passed').length,failed:results.filter(x=>x.status==='failed').length,results,
    limitations:['Real migrated PostgreSQL constraints and lease-update SQL predicates in one embedded session','Canonical signature calculation is covered by PaymentChecks; this suite checks persisted key uniqueness','Does not execute C# saga/worker, multi-session races, a provider payment, or end-to-end checkout']};
  if(process.argv[3]){const output=path.resolve(process.argv[3]);fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');}
  console.log(JSON.stringify(report,null,2));process.exitCode=report.failed?1:0;
});
