import { NextResponse, type NextRequest } from "next/server";
import { backendUrl } from "@/lib/backend";

// 同源轉發:瀏覽器只打這個網站的 /api/*,這裡在執行時改寫到後端,換 BACKEND_URL 不用重 build。
// 請求標頭(含 HttpOnly session cookie)與回應標頭(Set-Cookie)原樣通過。
export function proxy(request: NextRequest) {
  const base = backendUrl();
  if (!base) {
    return NextResponse.json(
      { error: { code: "backend_not_configured", message: "BACKEND_URL is not set" } },
      { status: 503 },
    );
  }
  const { pathname, search } = request.nextUrl;
  return NextResponse.rewrite(new URL(`${base}${pathname}${search}`));
}

export const config = {
  matcher: "/api/:path*",
};
