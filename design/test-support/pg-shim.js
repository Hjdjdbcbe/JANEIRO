/* Test-only stand-in for node-postgres, backed by the psql CLI.
   A transaction is buffered: begin / set role / set_config are queued and
   replayed in the same psql run as the one data query that follows. */
const { execFileSync } = require("child_process");
const lit = v => {
  if (v === null || v === undefined) return "NULL";
  if (typeof v === "number" || typeof v === "bigint") return String(v);
  if (typeof v === "boolean") return v ? "true" : "false";
  if (v instanceof Date) return `'${v.toISOString()}'`;
  if (Buffer.isBuffer(v)) return `'\\x${v.toString("hex")}'::bytea`;
  if (typeof v === "object") v = JSON.stringify(v);
  return "'" + String(v).replace(/'/g, "''") + "'";
};
const bind = (sql, params = []) => sql.replace(/\$(\d+)/g, (m, n) => lit(params[+n - 1]));
const isCtl = s => /^\s*(begin|commit|rollback|set\s+local|select\s+set_config)\b/i.test(s);
const db = o => (o && o.database) || process.env.PGDATABASE;
function run(database, pre, sql) {
  const body = sql.trim().replace(/;\s*$/, "");
  const wrapped = /^\s*(insert|update|delete|with)\b/i.test(body) && /returning/i.test(body)
    ? `with __r as (${body}) select '<<<'||coalesce(json_agg(__r)::text,'[]')||'>>>' from __r`
    : /^\s*(select|with|values|table)\b/i.test(body)
      ? `select '<<<'||coalesce(json_agg(__r)::text,'[]')||'>>>' from (${body}) __r`
      : `${body}; select '<<<[]>>>'`;
  const script = [...pre, wrapped + ";", "commit;"].join("\n");
  let out;
  try {
    out = execFileSync("psql", ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", "/var/run/postgresql", "-d", database],
      { input: (pre.length ? "" : "begin;\n") + script, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], maxBuffer: 64 << 20 });
  } catch (e) {
    const msg = String(e.stderr || e.message).split("\n").find(l => /ERROR/.test(l)) || String(e.stderr || e.message);
    const err = new Error(msg.replace(/^psql:.*?ERROR:\s*/, "").trim());
    const code = String(e.stderr || "").match(/SQLSTATE[:\s]+([0-9A-Z]{5})/); if (code) err.code = code[1];
    const m2 = String(e.stderr || ""); if (!err.code) { if (/duplicate key/.test(m2)) err.code = "23505"; else if (/permission denied/.test(m2)) err.code = "42501"; else err.code = "P0001"; }
    throw err;
  }
  const m = out.match(/<<<([\s\S]*)>>>/);
  const rows = m ? JSON.parse(m[1]) : [];
  return { rows, rowCount: rows.length };
}
class Client {
  constructor(o) { this.database = db(o); this.pre = []; }
  async connect() { return this; }
  async query(sql, params) {
    if (typeof sql === "object") { params = sql.values; sql = sql.text; }
    const s = bind(sql, params);
    if (/^\s*begin/i.test(s)) { this.pre = [s.replace(/;?\s*$/, ";")]; return { rows: [] }; }
    if (/^\s*(commit|rollback)/i.test(s)) { this.pre = []; return { rows: [] }; }
    if (isCtl(s)) { this.pre.push(s.replace(/;?\s*$/, ";")); return { rows: [] }; }
    const pre = this.pre; this.pre = pre.length ? pre.filter(x => /^\s*begin/i.test(x)) : [];
    const r = run(this.database, pre, s);
    return r;
  }
  release() {} async end() {}
}
class Pool {
  constructor(o) { this.o = o; }
  async connect() { return new Client(this.o); }
  async query(sql, params) { return new Client(this.o).query(sql, params); }
  async end() {}
  on() {}
}
module.exports = { Pool, Client, types: { setTypeParser() {} } };
