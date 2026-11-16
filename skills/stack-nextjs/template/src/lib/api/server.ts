// Server Component / Route Handler 呼叫後端:直接打 API_PROXY_TARGET,
// 並把瀏覽器的 cookie(含 session)轉送過去。呼叫時一律動態渲染,build 時不打 API。
import { cookies } from "next/headers";
import { connection } from "next/server";
import createClient from "openapi-fetch";
import type { paths } from "./schema";

export async function serverApi() {
  await connection();
  const base = process.env.API_PROXY_TARGET;
  if (!base) throw new Error("API_PROXY_TARGET is not set");
  const cookie = (await cookies()).toString();
  return createClient<paths>({
    baseUrl: base.replace(/\/$/, ""),
    headers: cookie ? { cookie } : {},
    cache: "no-store",
  });
}
