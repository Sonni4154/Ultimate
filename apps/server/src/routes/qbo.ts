import { Router } from "express";
import crypto from "node:crypto";
import { db, pool } from "../db";
import { buildAuthorizeUrl, handleCallback, makeQboWebhookHandler } from "@qbo/token-manager";
import { env } from "../env";

const r = Router();

// Launch (browser-friendly redirect)
r.get("/quickbooks/launch", (_req, res) => {
  const state = crypto.randomBytes(16).toString("hex");
  res.redirect(302, buildAuthorizeUrl(state));
});

// JSON launcher (optional)
r.get("/api/integrations/quickbooks/connect", (_req, res) => {
  const state = crypto.randomBytes(16).toString("hex");
  res.json({ url: buildAuthorizeUrl(state) });
});

// OAuth callback with error handling (prevents 502)
r.get("/quickbooks/callback", async (req, res) => {
  try {
    const code = String(req.query.code || "");
    const realmId = String(req.query.realmId || "");
    const integrationId = env.QBO_INTEGRATION_ID || String(req.query.state || "");
    if (!code || !realmId || !integrationId) {
      return res.status(400).send("Missing code/realmId/integrationId");
    }
    await handleCallback(db as any, code, realmId, integrationId);
    res.send("Connected to QuickBooks — you can close this window.");
  } catch (e: any) {
    console.error("QBO callback error:", e?.stack || e);
    res.status(500).send("QuickBooks connection failed. Check server logs.");
  }
});

// Webhook
r.post("/api/webhooks/quickbooks", makeQboWebhookHandler(async (payload: unknown) => {
  console.log("QBO webhook payload", payload);
}));

// Simple Company Info test (confirms bearer works end-to-end)
r.get("/quickbooks/company", async (_req, res) => {
  try {
    const { rows } = await pool.query<{access_token: string; realm_id: string}>(
      `SELECT access_token, realm_id
         FROM qbo_tokens
        WHERE integration_id = $1
        ORDER BY updated_at DESC
        LIMIT 1`,
      [env.QBO_INTEGRATION_ID || ""]
    );
    const row = rows[0];
    if (!row?.access_token || !row?.realm_id) {
      return res.status(404).json({ error: "No token/realm found" });
    }
    const base =
      env.QBO_ENV === "production"
        ? "https://quickbooks.api.intuit.com"
        : "https://sandbox-quickbooks.api.intuit.com";
    const url = `${base}/v3/company/${row.realm_id}/companyinfo/${row.realm_id}?minorversion=76`;
    const resp = await fetch(url, {
      headers: { Authorization: `Bearer ${row.access_token}`, Accept: "application/json" }
    });
    const json = await resp.json().catch(() => ({}));
    return res.status(resp.ok ? 200 : resp.status).json(json);
  } catch (e: any) {
    console.error("company info error:", e?.stack || e);
    return res.status(500).json({ error: "Failed to fetch company info" });
  }
});

export default r;
