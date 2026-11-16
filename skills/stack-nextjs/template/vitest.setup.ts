import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

// Vitest 沒開 globals,Testing Library 不會自動清理 DOM;每個測試後手動清。
afterEach(() => cleanup());
