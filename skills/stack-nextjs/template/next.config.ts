import type { NextConfig } from "next";

// 瀏覽器一律打相對路徑 /api/...,由這裡轉發到後端。
// API_PROXY_TARGET 沒設時不加 rewrites(build 不會失敗);next build 時就會固定下來,
// 所以 build 與 start 都要帶同一個值。
const target = process.env.API_PROXY_TARGET?.replace(/\/$/, "");

const nextConfig: NextConfig = {
  async rewrites() {
    if (!target) return [];
    return [{ source: "/api/:path*", destination: `${target}/api/:path*` }];
  },
};

export default nextConfig;
