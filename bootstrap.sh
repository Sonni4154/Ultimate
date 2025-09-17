#!/usr/bin/env bash
set -euo pipefail

# ===== Config you can tweak later =====
APP_DIR="/opt/wmx"
DOMAIN="wemakemarin.com"
DB_MODE="local"  # "local" (docker Postgres) or "neon"
NEON_DATABASE_URL="postgres://<user>:<password>@<neon-host>/<db>?sslmode=require"

QBO_CLIENT_ID=""
QBO_CLIENT_SECRET=""
QBO_WEBHOOK_VERIFIER_TOKEN=""
QBO_ENV="sandbox"
QBO_REDIRECT_URI="https://wemakemarin.com/quickbooks/callback"
QBO_INTEGRATION_ID=""  # set if you pre-seed an integrations row

# ===== Base packages (Docker + Nginx; Node optional) =====
sudo apt-get update
sudo apt-get install -y ca-certificates curl git gnupg lsb-release
sudo apt-get install -y docker.io gh nginx
# optional NodeJS (nice to have, not required for Docker build)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || true
sudo apt-get install -y nodejs || true

# ===== Project directories =====
sudo mkdir -p "$APP_DIR"
sudo chown "$USER:$USER" "$APP_DIR"
mkdir -p "$APP_DIR"/{apps/server/src/{routes,middlewares},packages/qbo-token-manager/{src,migrations},infra/{docker,pm2,nginx,scripts}}

# ===== Root files =====
cat > "$APP_DIR/package.json" <<'EOF'
{
  "name": "wmx",
  "private": true,
  "version": "0.1.0",
  "workspaces": ["apps/*", "packages/*"],
  "scripts": {
    "build": "pnpm -r build",
    "dev": "pnpm --filter server dev",
    "lint": "echo \"(no lint configured)\""
  }
}
EOF

cat > "$APP_DIR/pnpm-workspace.yaml" <<'EOF'
packages:
  - "apps/*"
  - "packages/*"
EOF

cat > "$APP_DIR/tsconfig.base.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2021",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "resolveJsonModule": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "strict": true,
    "forceConsistentCasingInFileNames": true,
    "baseUrl": ".",
    "paths": {
      "@qbo/token-manager": ["packages/qbo-token-manager/src"]
    }
  }
}
EOF

# ===== Server (apps/server) =====
cat > "$APP_DIR/apps/server/package.json" <<'EOF'
{
  "name": "server",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc -b",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "date-fns": "^3.6.0",
    "drizzle-orm": "^0.33.0",
    "express": "^4.19.2",
    "pg": "^8.12.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "tsx": "^4.16.2",
    "typescript": "^5.5.3"
  }
}
EOF

cat > "$APP_DIR/apps/server/tsconfig.json" <<'EOF'
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "types": ["node"],
    "jsx": "react-jsx"
  },
  "include": ["src"]
}
EOF

cat > "$APP_DIR/apps/server/src/env.ts" <<'EOF'
import { z } from "zod";
export const Env = z.object({
  PORT: z.string().default("3000"),
  DATABASE_URL: z.string(),
  QBO_CLIENT_ID: z.string(),
  QBO_CLIENT_SECRET: z.string(),
  QBO_REDIRECT_URI: z.string(),      // e.g., https://wemakemarin.com/quickbooks/callback
  QBO_ENV: z.enum(["sandbox","production"]).default("sandbox"),
  QBO_WEBHOOK_VERIFIER_TOKEN: z.string(),
  QBO_INTEGRATION_ID: z.string().optional()
});
export type Env = z.infer<typeof Env>;
export const env = Env.parse(process.env);
EOF

cat > "$APP_DIR/apps/server/src/db.ts" <<'EOF'
import { drizzle } from "drizzle-orm/node-postgres";
import pkg from "pg";
import { env } from "./env";
const { Pool } = pkg;
export const pool = new Pool({ connectionString: env.DATABASE_URL });
export const db = drizzle(pool);
process.on("SIGINT", async () => { await pool.end(); process.exit(0); });
EOF

cat > "$APP_DIR/apps/server/src/middlewares/rawBody.ts" <<'EOF'
import type { Request, Response, NextFunction } from "express";
export function captureRawBody(req: Request, _res: Response, next: NextFunction) {
  let data = Buffer.alloc(0);
  req.on("data", (chunk) => { data = Buffer.concat([data, chunk]); });
  req.on("end", () => { (req as any).rawBody = data.toString("utf8"); next(); });
}
EOF

cat > "$APP_DIR/apps/server/src/routes/health.ts" <<'EOF'
import { Router } from "express";
const r = Router();
r.get("/health", (_req, res) => res.json({ ok: true }));
export default r;
EOF

cat > "$APP_DIR/apps/server/src/routes/qbo.ts" <<'EOF'
import { Router } from "express";
import crypto from "node:crypto";
import { db } from "../db";
import { buildAuthorizeUrl, handleCallback, makeQboWebhookHandler } from "@qbo/token-manager";
import { env } from "../env";
const r = Router();

r.get("/api/integrations/quickbooks/connect", (_req, res) => {
  const state = crypto.randomBytes(16).toString("hex");
  res.json({ url: buildAuthorizeUrl(state) });
});

r.get("/quickbooks/callback", async (req, res) => {
  const code = String(req.query.code || "");
  const realmId = String(req.query.realmId || "");
  const integrationId = env.QBO_INTEGRATION_ID || String(req.query.state || "");
  await handleCallback(db as any, code, realmId, integrationId);
  res.send("Connected to QuickBooks — you can close this window.");
});

r.post("/api/webhooks/quickbooks", makeQboWebhookHandler(async (payload) => {
  console.log("QBO webhook payload", payload);
}));

export default r;
EOF

cat > "$APP_DIR/apps/server/src/index.ts" <<'EOF'
import express from "express";
import cors from "cors";
import { env } from "./env";
import health from "./routes/health";
import qbo from "./routes/qbo";
import { captureRawBody } from "./middlewares/rawBody";

const app = express();

// Raw body for webhooks BEFORE json()
app.post("/api/webhooks/quickbooks", captureRawBody, (req, res, next) => next());

app.use(express.json());
app.use(cors());
app.use(health);
app.use(qbo);

app.listen(Number(env.PORT), () => console.log(`API listening on :${env.PORT}`));
EOF

# ===== Token Manager package (packages/qbo-token-manager) =====
cat > "$APP_DIR/packages/qbo-token-manager/package.json" <<'EOF'
{
  "name": "@qbo/token-manager",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "peerDependencies": {
    "drizzle-orm": "^0.33.0"
  }
}
EOF

cat > "$APP_DIR/packages/qbo-token-manager/tsconfig.json" <<'EOF'
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": { "outDir": "dist" },
  "include": ["src"]
}
EOF

cat > "$APP_DIR/packages/qbo-token-manager/src/models.ts" <<'EOF'
import { pgTable, uuid, text, timestamp, boolean, integer } from "drizzle-orm/pg-core";

export const integrations = pgTable("integrations", {
  id: uuid("id").primaryKey().defaultRandom(),
  provider: text("provider").notNull(),
  orgId: uuid("org_id").notNull(),
  isActive: boolean("is_active").notNull().default(true),
  lastSyncAt: timestamp("last_sync_at"),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow()
});

export const qboTokens = pgTable("qbo_tokens", {
  integrationId: uuid("integration_id").primaryKey().references(() => integrations.id),
  accessToken: text("access_token").notNull(),
  refreshToken: text("refresh_token").notNull(),
  expiresAt: timestamp("expires_at").notNull(),
  realmId: text("realm_id").notNull(),
  version: integer("version").notNull().default(0),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow()
});
EOF

cat > "$APP_DIR/packages/qbo-token-manager/src/auth.ts" <<'EOF'
import crypto from "node:crypto";
import { addSeconds, isBefore } from "date-fns";
import { qboTokens } from "./models";
import type { DB } from "./types";
import { eq } from "drizzle-orm";

const QBO_AUTH_BASE = "https://appcenter.intuit.com/connect/oauth2";
const QBO_TOKEN_URL = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer";

export function buildAuthorizeUrl(state: string) {
  const params = new URLSearchParams({
    client_id: process.env.QBO_CLIENT_ID!,
    response_type: "code",
    scope: [
      "com.intuit.quickbooks.accounting",
      "openid","profile","email","phone","address"
    ].join(" "),
    redirect_uri: process.env.QBO_REDIRECT_URI!,
    state
  });
  return `${QBO_AUTH_BASE}?${params.toString()}`;
}

async function exchangeCode(code: string) {
  const b64 = Buffer.from(`${process.env.QBO_CLIENT_ID!}:${process.env.QBO_CLIENT_SECRET!}`).toString("base64");
  const res = await fetch(QBO_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${b64}` },
    body: new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: process.env.QBO_REDIRECT_URI! })
  });
  if (!res.ok) throw new Error(`QBO exchange failed: ${await res.text()}`);
  return res.json() as Promise<{ access_token: string; refresh_token: string; expires_in: number; x_refresh_token_expires_in: number }>;
}

async function refresh(refreshToken: string) {
  const b64 = Buffer.from(`${process.env.QBO_CLIENT_ID!}:${process.env.QBO_CLIENT_SECRET!}`).toString("base64");
  const res = await fetch(QBO_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${b64}` },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken })
  });
  if (!res.ok) throw new Error(`QBO refresh failed: ${await res.text()}`);
  return res.json() as Promise<{ access_token: string; refresh_token: string; expires_in: number }>;
}

export async function handleCallback(db: DB, code: string, realmId: string, integrationId: string) {
  const tok = await exchangeCode(code);
  const expiresAt = addSeconds(new Date(), tok.expires_in - 60);
  await db.insert(qboTokens).values({ integrationId, accessToken: tok.access_token, refreshToken: tok.refresh_token, expiresAt, realmId })
    .onConflictDoUpdate({ target: qboTokens.integrationId, set: { accessToken: tok.access_token, refreshToken: tok.refresh_token, expiresAt } });
}

export async function getAccessToken(db: DB, integrationId: string) {
  const [row] = await db.select().from(qboTokens).where(eq(qboTokens.integrationId, integrationId));
  if (!row) throw new Error("QBO tokens not found");
  if (isBefore(row.expiresAt, new Date())) {
    const upd = await refresh(row.refreshToken);
    const expiresAt = addSeconds(new Date(), upd.expires_in - 60);
    await db.update(qboTokens).set({ accessToken: upd.access_token, refreshToken: upd.refresh_token, expiresAt }).where(eq(qboTokens.integrationId, integrationId));
    return { token: upd.access_token, realmId: row.realmId };
  }
  return { token: row.accessToken, realmId: row.realmId };
}

export function verifyWebhookSignature(rawBody: string, signatureHeader: string) {
  const key = process.env.QBO_WEBHOOK_VERIFIER_TOKEN!;
  const hmac = crypto.createHmac("sha256", key).update(rawBody).digest("base64");
  return crypto.timingSafeEqual(Buffer.from(signatureHeader || ""), Buffer.from(hmac));
}
EOF

cat > "$APP_DIR/packages/qbo-token-manager/src/client.ts" <<'EOF'
import type { DB } from "./types";
import { getAccessToken } from "./auth";

function baseUrl(realmId: string) {
  const domain = process.env.QBO_ENV === "production" ? "quickbooks.api.intuit.com" : "sandbox-quickbooks.api.intuit.com";
  return `https://${domain}/v3/company/${realmId}`;
}
export async function qboFetch(db: DB, integrationId: string, path: string, init?: RequestInit) {
  const { token, realmId } = await getAccessToken(db, integrationId);
  const res = await fetch(`${baseUrl(realmId)}${path}`, {
    ...init,
    headers: { Accept: "application/json", "Content-Type": "application/json", Authorization: `Bearer ${token}`, ...(init?.headers || {}) }
  });
  if (!res.ok) throw new Error(`QBO API ${path} failed: ${res.status} ${await res.text()}`);
  return res.json();
}
EOF

cat > "$APP_DIR/packages/qbo-token-manager/src/webhooks.ts" <<'EOF'
import type { RequestHandler } from "express";
import { verifyWebhookSignature } from "./auth";
export function makeQboWebhookHandler(onEvent: (payload: any) => Promise<void>): RequestHandler {
  return async (req, res) => {
    const signature = req.header("intuit-signature") || "";
    const raw = (req as any).rawBody || JSON.stringify(req.body);
    if (!verifyWebhookSignature(raw, signature)) return res.status(401).send("invalid signature");
    await onEvent(JSON.parse(raw));
    res.status(200).send("ok");
  };
}
EOF

cat > "$APP_DIR/packages/qbo-token-manager/src/index.ts" <<'EOF'
export * from "./auth";
export * from "./client";
export * from "./models";
export * from "./webhooks";
export type DB = any;
EOF

cat > "$APP_DIR/packages/qbo-token-manager/migrations/2025-09-17_qbo_init.sql" <<'EOF'
create table if not exists integrations (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  org_id uuid not null,
  is_active boolean not null default true,
  last_sync_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table if not exists qbo_tokens (
  integration_id uuid primary key references integrations(id) on delete cascade,
  access_token text not null,
  refresh_token text not null,
  expires_at timestamptz not null,
  realm_id text not null,
  version int not null default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
EOF

# ===== Infra: Docker, PM2, Nginx, scripts =====
cat > "$APP_DIR/infra/docker/Dockerfile" <<'EOF'
FROM node:20-slim
WORKDIR /app
COPY package.json pnpm-lock.yaml* ./
RUN corepack enable && corepack prepare pnpm@9.7.0 --activate
COPY . .
RUN pnpm -r install
RUN pnpm -r build
ENV NODE_ENV=production
CMD ["pnpm","--filter","server","start"]
EOF

cat > "$APP_DIR/infra/docker/docker-compose.yml" <<'EOF'
version: "3.9"
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: app
    volumes: ["pgdata:/var/lib/postgresql/data"]
    ports: ["5432:5432"]

  api:
    build: ../..
    env_file: [".env"]
    environment:
      DATABASE_URL: ${DATABASE_URL}
      PORT: 3000
      QBO_CLIENT_ID: ${QBO_CLIENT_ID}
      QBO_CLIENT_SECRET: ${QBO_CLIENT_SECRET}
      QBO_REDIRECT_URI: ${QBO_REDIRECT_URI}
      QBO_ENV: ${QBO_ENV}
      QBO_WEBHOOK_VERIFIER_TOKEN: ${QBO_WEBHOOK_VERIFIER_TOKEN}
      QBO_INTEGRATION_ID: ${QBO_INTEGRATION_ID}
    ports: ["3000:3000"]
    depends_on: [db]
volumes:
  pgdata: {}
EOF

# Generate .env for docker-compose
if [ "$DB_MODE" = "neon" ]; then
  cat > "$APP_DIR/infra/docker/.env" <<EOF
DATABASE_URL=${NEON_DATABASE_URL}
PORT=3000
QBO_CLIENT_ID=${QBO_CLIENT_ID}
QBO_CLIENT_SECRET=${QBO_CLIENT_SECRET}
QBO_REDIRECT_URI=${QBO_REDIRECT_URI}
QBO_ENV=${QBO_ENV}
QBO_WEBHOOK_VERIFIER_TOKEN=${QBO_WEBHOOK_VERIFIER_TOKEN}
QBO_INTEGRATION_ID=${QBO_INTEGRATION_ID}
EOF
else
  cat > "$APP_DIR/infra/docker/.env" <<EOF
DATABASE_URL=postgres://postgres:postgres@db:5432/app
PORT=3000
QBO_CLIENT_ID=${QBO_CLIENT_ID}
QBO_CLIENT_SECRET=${QBO_CLIENT_SECRET}
QBO_REDIRECT_URI=${QBO_REDIRECT_URI}
QBO_ENV=${QBO_ENV}
QBO_WEBHOOK_VERIFIER_TOKEN=${QBO_WEBHOOK_VERIFIER_TOKEN}
QBO_INTEGRATION_ID=${QBO_INTEGRATION_ID}
EOF
fi

cat > "$APP_DIR/infra/pm2/ecosystem.config.cjs" <<'EOF'
module.exports = {
  apps: [
    { name: "api", script: "apps/server/dist/index.js", env: { NODE_ENV: "production", PORT: 3000 } }
  ]
};
EOF

cat > "$APP_DIR/infra/nginx/wemakemarin.conf" <<EOF
server {
  listen 80;
  server_name ${DOMAIN};
  access_log /var/log/nginx/${DOMAIN}.access.log;
  error_log  /var/log/nginx/${DOMAIN}.error.log;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

cat > "$APP_DIR/infra/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR=/opt/wmx
cd "$APP_DIR/infra/docker"
docker compose up -d --build
EOF
chmod +x "$APP_DIR/infra/scripts/update.sh"

# Enable nginx site
sudo ln -sf "$APP_DIR/infra/nginx/wemakemarin.conf" "/etc/nginx/sites-available/wemakemarin.conf"
sudo ln -sf "/etc/nginx/sites-available/wemakemarin.conf" "/etc/nginx/sites-enabled/wemakemarin.conf"
sudo nginx -t && sudo systemctl reload nginx

# ===== Build & run (Docker) =====
cd "$APP_DIR/infra/docker"
sudo docker compose up -d --build

# ===== Local DB migration (if using local Postgres service) =====
if [ "$DB_MODE" != "neon" ]; then
  echo "Applying DB migrations to local docker Postgres..."
  sudo docker exec -i "$(sudo docker ps -qf name=db)" psql -U postgres -d app < "$APP_DIR/packages/qbo-token-manager/migrations/2025-09-17_qbo_init.sql"
else
  echo "Using Neon DB mode — apply migrations to Neon separately."
fi

echo "All set. Health:  http://${DOMAIN}/health"
echo "Kick off OAuth:  https://${DOMAIN}/api/integrations/quickbooks/connect"
REMOTE_BOOTSTRAP
echo "Remote bootstrap complete."
