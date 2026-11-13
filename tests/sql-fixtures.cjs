const crypto = require('node:crypto');
const assert = require('node:assert/strict');
async function insert(db, table, overrides = {}) {
  const columns = (await db.query('SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2 ORDER BY ordinal_position', ['public', table])).rows;
  assert.ok(columns.length, `Missing fixture table ${table}`);
  const row = {};
  for (const column of columns) {
    row[column.column_name] = column.is_nullable === 'YES' ? null
      : column.data_type === 'uuid' ? crypto.randomUUID()
      : column.data_type === 'boolean' ? false
      : ['integer','bigint','numeric','double precision'].includes(column.data_type) ? (column.column_name === 'RequestsPerMinute' ? 120 : 1)
      : column.data_type.includes('timestamp') ? '2026-11-13T00:00:00Z'
      : column.data_type === 'jsonb' ? '{}' : 'fixture';
  }
  Object.assign(row, overrides);
  const fields = Object.keys(row);
  await db.query(`INSERT INTO "${table}" (${fields.map(x=>`"${x}"`).join(',')}) VALUES (${fields.map((_,i)=>`$${i+1}`).join(',')})`,fields.map(x=>row[x]));
  return row;
}
module.exports = { insert };
