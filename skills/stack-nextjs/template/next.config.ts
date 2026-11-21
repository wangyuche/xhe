import type { NextConfig } from "next";

// /api/* 由 src/proxy.ts 在「每個請求」讀 BACKEND_URL(備援 API_PROXY_TARGET)轉發,
// 不用 rewrites(rewrites 在 next build 時就固定)。同一個 build / Docker 映像可接任何後端。
// output: "standalone":npm run build 產生 .next/standalone/server.js(postbuild 會複製 static 與 public),
// npm start 與 Docker 都跑它。
const nextConfig: NextConfig = {
  output: "standalone",
};

export default nextConfig;
