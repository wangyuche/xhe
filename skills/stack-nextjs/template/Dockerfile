# syntax=docker/dockerfile:1
# 只支援 npm(package-lock.json + npm ci);pnpm / yarn / bun 專案要自行改 deps 階段。
# Next.js standalone 映像。build context:前端目錄(docker compose 的 ./frontend)。
# BACKEND_URL 在執行時由 src/proxy.ts / src/lib/api/server.ts 讀取,同一個映像可接任何後端:
#   docker compose 設 environment: BACKEND_URL: http://backend:8080
# src/lib/api/schema.d.ts 要提交(由 ../api/openapi.yaml 產生,契約在 build context 之外),這裡不跑 gen:api。

FROM node:24-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM node:24-alpine AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# npm run build 的 postbuild 會把 .next/static 與 public 複製進 .next/standalone
RUN npm run build

FROM node:24-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
COPY --from=build --chown=node:node /app/.next/standalone ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/').then(r=>process.exit(r.status<500?0:1),()=>process.exit(1))"]
CMD ["node", "server.js"]
