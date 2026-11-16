-- +goose Up
-- 第一個 migration 只建立 goose 需要的狀態;實際資料表從 0002 開始。
SELECT 1;

-- +goose Down
SELECT 1;
