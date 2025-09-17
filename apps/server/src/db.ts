import { drizzle } from "drizzle-orm/node-postgres";
import pkg from "pg";
import { env } from "./env";
const { Pool } = pkg;
export const pool = new Pool({ connectionString: env.DATABASE_URL });
export const db = drizzle(pool);
process.on("SIGINT", async () => { await pool.end(); process.exit(0); });
