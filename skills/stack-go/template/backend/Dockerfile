# syntax=docker/dockerfile:1
# 多階段建置:Go 工具鏈只在 build 階段;最終映像是 distroless static(無 shell、無 curl、非 root)。
# compose healthcheck 用 ["CMD", "/server", "healthcheck"](打 127.0.0.1:$PORT/healthz)。
# Go 版本要和 stack-go 的 GO_MIN 一致(scripts/versions.sh)。

FROM golang:1.26-alpine AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server \
 && mkdir -p /out/app/data

FROM gcr.io/distroless/static-debian12:nonroot
# 沒設 DATABASE_URL 時用相對路徑 SQLite data/dev.db:WORKDIR 是 /app,其下的 /app/data 必須是 nonroot 可寫
# (distroless 沒有 shell,用 COPY --chown 建目錄)。容器刪掉資料就沒了;要保留請掛 volume 到 /app/data 或用 PostgreSQL。
COPY --from=build --chown=nonroot:nonroot /out/app /app
COPY --from=build /out/server /server
WORKDIR /app
USER nonroot:nonroot
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 CMD ["/server", "healthcheck"]
ENTRYPOINT ["/server"]
