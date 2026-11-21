import type { NextConfig } from "next";

// /api/* 由 src/proxy.ts 在「每個請求」讀 BACKEND_URL(備援 API_PROXY_TARGET)轉發,
// 不用 rewrites(rewrites 在 next build 時就固定)。同一個 build / Docker 映像可接任何後端。
// output: "standalone":npm run build 產生 .next/standalone/server.js(postbuild 會複製 static 與 public),
// npm start 與 Docker 都跑它。
// outputFileTracingRoot / turbopack.root 固定為前端目錄:外層(repo 根目錄、$HOME)有其他 lockfile 時,
// Next 會把 workspace 根推到外層,server.js 就跑到 .next/standalone/<相對路徑>/,npm start 找不到。
const root = process.cwd();
const nextConfig: NextConfig = {
  output: "standalone",
  outputFileTracingRoot: root,
  turbopack: { root },
};

export default nextConfig;
