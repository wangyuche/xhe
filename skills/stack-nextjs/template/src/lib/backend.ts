// 後端網址,每次呼叫時讀取(不會在 build 時寫死)。
// BACKEND_URL:docker compose / 部署用;API_PROXY_TARGET:本機 serve.sh 的備援名稱。
export function backendUrl(): string | undefined {
  const raw = process.env.BACKEND_URL || process.env.API_PROXY_TARGET;
  return raw ? raw.replace(/\/+$/, "") : undefined;
}
