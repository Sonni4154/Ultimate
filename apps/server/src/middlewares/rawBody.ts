import type { Request, Response, NextFunction } from "express";
export function captureRawBody(req: Request, _res: Response, next: NextFunction) {
  let data = Buffer.alloc(0);
  req.on("data", (chunk) => { data = Buffer.concat([data, chunk]); });
  req.on("end", () => { (req as any).rawBody = data.toString("utf8"); next(); });
}
