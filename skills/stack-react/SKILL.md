---
name: stack-react
description: React 19 元件規則(函式元件、hooks、狀態、無障礙)與 Vitest + Testing Library 測試寫法、驗收情境測試命名。frontend-owner 寫 React 元件與元件測試時使用;碰到 .tsx / .jsx 時也適用。
paths: ["**/*.tsx", "**/*.jsx"]
---

# stack-react

## 元件
1. 只用函式元件與 hooks;一個檔案一個主要元件,檔名 PascalCase(`LoginForm.tsx`)。props 用 TypeScript 型別明寫,不用 `any`。
2. **衍生資料不放 state**:能從 props / state 算出來的就在 render 時算;不用 `useEffect` 同步兩個 state。`useEffect` 只用於和外部系統同步(訂閱、計時器、DOM API)。
3. hooks 只在元件頂層呼叫;依賴陣列寫完整,不靠關閉 lint 規則。
4. 列表的 `key` 用穩定 id,不用 index(除非列表不會變動)。
5. 表單:受控元件或 `<form action>`;送出中停用按鈕並避免重複送出;後端錯誤(`{"error":{"code","message"}}`)顯示在表單附近。
6. 樣式:CSS Modules(`*.module.css`),不加樣式框架(Tailwind 未採用)。版面在 390 px 寬不可橫向捲動(用 `max-width: 100%`、`flex-wrap`、避免固定寬度)。

## 無障礙(最低要求)
- 每個輸入框有 `<label htmlFor>` 或 `aria-label`;按鈕是 `<button>`,不用可點擊的 `<div>`。
- 錯誤訊息用 `role="alert"` 或以 `aria-describedby` 連到輸入框。
- 主要流程能只用鍵盤完成(Tab 順序合理、focus 可見)。
- 圖片有 `alt`(裝飾性圖片 `alt=""`)。

## 測試(Vitest + Testing Library)
```tsx
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test } from "vitest";
import { LoginForm } from "./LoginForm";

describe("LoginForm", () => {
  test("LOGIN-S4: 未填 email 時按鈕停用", async () => {
    render(<LoginForm onSubmit={async () => {}} />);
    expect(screen.getByRole("button", { name: "登入" })).toBeDisabled();
  });
});
```
- 測試檔放在元件旁邊:`LoginForm.test.tsx`。查元素優先用 `getByRole` / `getByLabelText`(順便驗證無障礙),不用 class 或 test id。
- 互動用 `userEvent`,不用 `fireEvent`。
- 驗收情境的測試名稱以「情境編號 + 冒號」開頭(`LOGIN-S3: …`);其他測試自由命名。
- 新增的元件(不含 `page.tsx`、`layout.tsx`)至少一個測試。元件測試不打真實 API:把呼叫 API 的函式當 props 傳入,或用 `vi.mock` 換掉 `@/lib/api/client`。
