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
