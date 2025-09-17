import express from "express";
import cors from "cors";
import { env } from "./env";
import health from "./routes/health";
import qbo from "./routes/qbo";
import { captureRawBody } from "./middlewares/rawBody";

const app = express();

// Raw body ONLY for the webhook
app.post("/api/webhooks/quickbooks", captureRawBody, (req, _res, next) => next());

// JSON & CORS for everything else
app.use(express.json());
app.use(cors());

// Routes
app.use(health);
app.use(qbo);

// Friendly root
app.get("/", (_req, res) => res.send("WMX API is live."));

app.listen(Number(env.PORT), "0.0.0.0", () => {
  console.log(`API listening on :${env.PORT}`);
});
