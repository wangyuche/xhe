# 效能預算

<!-- stack-pixi:標題固定(各一次);表格第一欄是量測腳本讀的 key,第二欄是門檻(數字),可接「(推定)」;「—」= 未設定(量測只記錄、不擋)。
     數值每個專案不同,由簡報或使用者決定;推定的值要標「(推定)」並請使用者確認。量測方法見 tests/perf/。 -->

## 首屏
量測:production build + gzip(scripts/serve-dist.mjs)、Slow 4G + 4× CPU、冷快取、5 次中位數;1920×1080 與 844×390@3x。

| key | 門檻 | 說明 |
|---|---|---|
| fcp_ms | __FCP__ | First Contentful Paint |
| interactive_ms | __INTERACTIVE__ | `#loading` 隱藏的時間 |
| tbt_ms | __TBT__ | 可互動前的 Total Blocking Time |

## 場景切換
| key | 門檻 | 說明 |
|---|---|---|
| scene_ready_ms | __SCENE__ | 觸發切換到 `<scene>:ready` mark(限速在首屏後才開) |

## 傳輸量
| key | 門檻 | 說明 |
|---|---|---|
| boot_kb | __BOOT__ | 可互動前的傳輸量(gzip 後,KB);BGM 不得計入(PX-LOAD-06;BGM 第一次手勢後才下載,PX-LOAD-10) |

## 長時間遊玩
| key | 門檻 | 說明 |
|---|---|---|
| soak_rounds | __ROUNDS__ | 輪數(前 1/3、最多 10 輪暖機) |
| soak_heap_pct | __HEAP__ | 暖機後到結束的 heap 增加 % |
| soak_dom_nodes | __NODES__ | DOM 節點增加數 |
| soak_listeners | __LISTENERS__ | 事件監聽增加數 |
| soak_objects | __OBJECTS__ | stage 物件增加數 |

## 素材預算
每個群組的 AVIF 合計(KB);`scripts/build-assets.mjs` 與 stack-pixi `check-assets` 超過就失敗。

| group | 1x_kb | 0.5x_kb |
|---|---|---|

## 例外
<!-- 專案對 PX 規則的例外:編號、規則、做法、理由、何時失效。沒有就寫「無」。 -->
無

## 最新實測
<!-- 「不得退步」的基準:每次量測後更新(日期、commit、view、各 key 的中位數)。 -->
