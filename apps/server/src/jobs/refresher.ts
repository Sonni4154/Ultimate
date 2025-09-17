import { pool } from "../db";
import { env } from "../env";

const SKEW_MINUTES = 5;
const BATCH_LIMIT  = 50;
const INTERVAL_MIN = 10;

type TokenRow = { integration_id: string; realm_id: string | null; refresh_token: string | null; };

async function refreshOne(row: TokenRow) {
  if (!row.refresh_token) return false;
  const basic = Buffer.from(`${env.QBO_CLIENT_ID}:${env.QBO_CLIENT_SECRET}`).toString("base64");
  const params = new URLSearchParams({ grant_type: "refresh_token", refresh_token: row.refresh_token });
  const resp = await fetch("https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer", {
    method: "POST",
    headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: params,
  });
  if (!resp.ok) throw new Error(`Intuit refresh failed ${resp.status}: ${await resp.text().catch(()=> "")}`);
  const json: any = await resp.json();
  const accessToken = json.access_token as string;
  const newRefresh  = (json.refresh_token as string) || row.refresh_token;
  const expiresIn   = Number(json.expires_in || 3600);
  await pool.query(
    `UPDATE qbo_tokens
       SET access_token = $1,
           refresh_token = $2,
           expires_at   = NOW() + ($3 || ' seconds')::interval,
           updated_at   = NOW()
     WHERE integration_id = $4
       AND realm_id IS NOT DISTINCT FROM $5`,
    [accessToken, newRefresh, String(expiresIn), row.integration_id, row.realm_id]
  );
  return true;
}

async function tick() {
  const { rows } = await pool.query<TokenRow>(
    `SELECT integration_id, realm_id, refresh_token
       FROM qbo_tokens
      WHERE (expires_at IS NULL OR expires_at <= NOW() + ($1 || ' minutes')::interval)
      ORDER BY COALESCE(expires_at, NOW()) ASC
      LIMIT $2`,
    [String(SKEW_MINUTES), String(BATCH_LIMIT)]
  );
  let ok = 0, fail = 0;
  for (const r of rows) { try { if (await refreshOne(r)) ok++; } catch (e) { console.error("[refresher] row", r, e); fail++; } }
  console.log(`[refresher] done: refreshed=${ok} failed=${fail}`);
}
(async () => { console.log(`[refresher] starting, every ${INTERVAL_MIN}m`); await tick(); setInterval(tick, INTERVAL_MIN*60*1000); })();
