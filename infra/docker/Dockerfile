FROM node:20-slim

ENV CI=1 PNPM_CONFIG_FROZEN_LOCKFILE=false
WORKDIR /app

COPY package.json pnpm-lock.yaml* ./
RUN corepack enable && corepack prepare pnpm@10.17.0 --activate

# install all workspaces
COPY . .
RUN pnpm -r install --no-frozen-lockfile
RUN pnpm -r build

EXPOSE 3000
# probe /health inside the container
HEALTHCHECK --interval=10s --timeout=3s --retries=10 CMD node -e "http=require('http');http.get('http://127.0.0.1:'+ (process.env.PORT||3000) +'/health',res=>{process.exit(res.statusCode===200?0:1)}).on('error',()=>process.exit(1))"

ENV NODE_ENV=production
CMD ["node","apps/server/dist/index.js"]
