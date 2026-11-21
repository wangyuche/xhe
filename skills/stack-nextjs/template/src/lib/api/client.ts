// 瀏覽器端(Client Component)呼叫後端:一律相對路徑 /api/...,由 src/proxy.ts 在執行時轉發到 BACKEND_URL。
// session cookie 是同源 HttpOnly cookie,瀏覽器會自動帶上。
import createClient from "openapi-fetch";
import type { paths } from "./schema";

export const api = createClient<paths>({
  baseUrl: typeof window === "undefined" ? "http://localhost" : window.location.origin,
  credentials: "same-origin",
});
