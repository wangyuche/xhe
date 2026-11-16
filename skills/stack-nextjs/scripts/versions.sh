# stack-nextjs 固定版本(由其他腳本 source)。依 npm registry 2026-11-16 查得的最新版。
NODE_MIN="24.18.0"           # @stoplight/prism-cli 5.16 要求 >=24.18;jsdom 31 要求 ^22.22 || >=24
CNA_VERSION="16.4.6"         # create-next-app(next 16.4.6)
RUNTIME_DEPS=("openapi-fetch@0.17.0")
DEV_DEPS=(
  "@types/node@^24"           # create-next-app 預設 ^20,vitest 5 要求 ^22 || >=24
  "vitest@5.1.0" "@vitejs/plugin-react@6.3.0" "jsdom@31.0.1"
  "@testing-library/react@16.3.3" "@testing-library/jest-dom@7.0.1" "@testing-library/user-event@14.6.12"
  "@playwright/test@1.65.1"
  "openapi-typescript@7.13.0" "@stoplight/prism-cli@5.16.0"
)

node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v; v="$(node -p 'process.versions.node' 2>/dev/null)"
  [ "$(printf '%s\n%s\n' "$NODE_MIN" "$v" | sort -V | head -1)" = "$NODE_MIN" ]
}
