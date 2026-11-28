---
name: gcp-ops-kit
description: GCP 專案 / GKE 審查與受控變更的固定腳本(gcp-guardian 使用):check.sh(依模式檢查工具、設定檔與金鑰權限、SA 能否存取專案)、collect.sh(逐條 regex 白名單 + 拒絕樣式的唯讀盤點:IAM、SA 金鑰、網路 / 防火牆、GCS、Cloud SQL、Compute、GKE 與叢集內 workload / RBAC / NetworkPolicy,寫檔前遮蔽秘密,API 未啟用列「無法判定」)、gcp_rules.py / k8s_rules.py(固定嚴重度規則,對照 CIS GCP Foundations v3.0.0)、yaml-review.sh(k8s YAML / kustomize 審查,不需 GCP)、plan.py(變更計畫:快照、dry-run、依允許清單計算 kind / 可否還原 / 還原指令 / 是否放寬安全、sha256)、change.sh(只執行逐條核准且雜湊一致的條目,重算分類、比對 precondition 與叢集 endpoint、before / after、失敗即停、不自動還原)、render.mjs(單一自足 HTML 報告與 --check)、guard.py(PreToolUse hook:只准 kit 入口腳本與唯讀指令)。每次執行獨立的 CLOUDSDK_CONFIG / KUBECONFIG,不碰使用者的 gcloud / kubectl 設定。selftest 只用假 gcloud / kubectl。
---

# gcp-ops-kit

`<kit>` = 這個 skill 的目錄(全域連結:`~/.claude/skills/gcp-ops-kit`)。所有指令都用**絕對路徑**呼叫入口腳本,一次一個,不串接(guard.py 會擋)。

## 本機設定(不進 git)

**沒有設定檔時**:直接用 gcloud 目前登入的帳號(`gcloud config get-value account`,即帳號模式),不用寫任何設定;專案 ID 由簡報指定。有設定檔時一律照設定檔走:沒寫 `GG_AUTH=user` 就是 SA 模式(缺金鑰 BLOCKED,不默默改用個人帳號)。要用 SA 金鑰、指定別的帳號、設預設專案或報告目錄時,才建 `~/.config/gcp-guardian/config`(只為了預設專案而建設定檔、又要用自己的帳號,也要寫 `GG_AUTH=user`)(權限 600,使用者建立):

```
# SA 金鑰(權限 600)
GG_SA_KEY_FILE=/絕對路徑/sa-key.json
# 選填:簡報沒給專案時用
GG_DEFAULT_PROJECT=my-project
# 選填:報告目錄,預設 ~/gcp-guardian-reports(不可含空白)
GG_REPORT_DIR=/Users/<你>/gcp-guardian-reports
```

值後面的 `  # 註解` 會被忽略。

**指定別的帳號(不需 SA 金鑰)**:設定檔改寫

```
GG_AUTH=user
# 你在本機 gcloud 登入的帳號(使用者自己先在終端機執行 gcloud auth login <帳號>)
GG_ACCOUNT=you@example.com
```

kit 每個 run 用 `gcloud config config-helper --min-expiry=15m --account=<帳號>` 取短效 token(保證至少還有 15 分鐘,每 5 分鐘換新,換新時清掉 GKE 外掛的 token 快取;帳號模式下沒走 `--async` 的變更逾時 8 分鐘;要重新驗證時直接失敗並提示 `gcloud auth login`),只寫進 `<run>/gcloud/token`(600,結束刪除),以 `CLOUDSDK_AUTH_ACCESS_TOKEN_FILE` 給 gcloud 與 GKE 外掛使用(2026-11-28 已用真的 gcloud 594 + 外掛實測 get-credentials 與 kubectl 可用);審查中途換 token 失敗時,該指令列入無法判定,不中斷整份報告;不複製、不讀你的憑證檔,`~/.config/gcloud` 仍受 guard 保護(gcloud 自己換新 token 時會更新它的快取)。你的 gcloud 設了 `auth/impersonate_service_account`、`auth/credential_file_override` 或 `auth/access_token_file` 時直接 BLOCKED(拿到的 token 不是你本人)。權限就是你帳號的權限:審查 / 計畫照樣只跑唯讀白名單,變更照樣要逐條核准;「不可動自己的 IAM 綁定」改成套用在這個帳號。報告的寫入權限提示依帳號在專案上的直接綁定判斷(透過群組取得的角色不會列出)。

使用者自己要裝:`brew install --cask gcloud-cli`(舊名 google-cloud-sdk)、`gcloud components install gke-gcloud-auth-plugin`。kit 不安裝任何東西。

## 入口腳本

結束碼(全部):0 成功 / PASS、1 有問題(ISSUES)、2 用法錯誤、3 BLOCKED、4 指令被白名單拒絕(kit 錯誤,回報)。

```bash
<kit>/scripts/check.sh yaml                         # ruby / python3 / node
<kit>/scripts/check.sh review|plan|change [<專案>] [--scope iam,gcs,…]  # 沒給專案用 GG_DEFAULT_PROJECT;scope 不含 gke / k8s 時不要求 kubectl;GG_AUTH=user 時不需金鑰; + 設定檔 / 金鑰 600、gcloud、gke-gcloud-auth-plugin、kubectl、SA 能存取專案、SA 角色

<kit>/scripts/collect.sh [<專案>] [--mode review|plan] [--scope iam,network,gcs,sql,compute,gke,k8s] [--clusters a,b] [--prev <上次 run>]
#   → run=<GG_REPORT_DIR>/<專案>/<時間>-<模式>/ :inventory/(遮蔽後)、findings.json、plan.json(空)、report.html
<kit>/scripts/yaml-review.sh <檔案或目錄>... [--label <名稱>]
#   → run=<GG_REPORT_DIR>/_yaml/<名稱>/<時間>-yaml/(與 GCP 專案分開)

<kit>/scripts/plan.py build <run>                   # 讀 <run>/plan.input.json → plan.json + sha256 + 重產報告
<kit>/scripts/plan.py show <plan.json>
<kit>/scripts/change.sh <plan.json> --sha <sha256> --approved "使用者已核准變更 C1, C3"
#   必須先有 <計畫 run>/approval.json(由主 agent 在使用者核准後寫入:{"sha256": "<plan sha256>", "approved": ["C1","C3"], "user_text": "<使用者原話>"}),
#   旗標的 sha256 與編號要和它完全一致(gcp-guardian 自己寫不了這個檔,所以不能自己核准);
#   執行時會把它改名為 approval.used-<run>.json(每份核准只能用一次);
#   只接受審查 / 計畫 run 目錄裡 plan.py 產生的 plan.json;旗標必須完全是「使用者已核准變更 C1, C3」(逗號或頓號分隔,不可夾其他文字)
#   → status=PASS|ISSUES|BLOCKED、run=<變更 run>、每條:C<n> 結果 原因 還原指令

node <kit>/scripts/render.mjs <run>                 # 寫了 manual.json 後重產報告
node <kit>/scripts/render.mjs --check <run>         # 整個 run 目錄無秘密樣式 / 未遮蔽值、HTML 無外部資源、統計一致、plan sha 一致、manual.json 格式
<kit>/scripts/selftest.sh [-v]                      # 只用 tests/stub 的假 gcloud / kubectl
```

## agent 可寫的兩個檔(其餘由 kit 產生)

**`<run>/manual.json`**:規則沒涵蓋、但從盤點看出的問題。陣列,同 findings 格式:

```json
[{"rule_id": "MANUAL-1", "severity": "中", "title": "…", "detail": "…", "resource": "…",
  "evidence": {"file": "inventory/…json", "path": "/JSON pointer"}, "fix": "…", "reason": "依嚴重度表的判定理由"}]
```

**`<run>/plan.input.json`**:變更計畫草稿。`kind` / `reversible` / `rollback` / `loosens_security` / `dry_run` 由 plan.py 計算,寫了也會被忽略。

```json
{"items": [{"id": "C1", "summary": "移除 bucket 公開讀取", "finding": "GCS-PUB-001",
  "command": ["gcloud", "storage", "buckets", "remove-iam-policy-binding", "gs://b", "--member=allUsers",
              "--role=roles/storage.objectViewer", "--project=p", "--condition=None"],
  "precondition": [{"binding_present": ["allUsers", "roles/storage.objectViewer"]}],
  "expected": [{"binding_absent": ["allUsers", "roles/storage.objectViewer"]}],
  "impact": "無"}]}
```

- `command`:argv 陣列;旗標一律 `--長旗標=值`(不接受 `-n`、`-f` 這種短旗標)。gcloud 必帶 `--project=`;kubectl 第二個參數必須是 `--context=gke_<專案>_<位置>_<叢集>`,namespace 用 `--namespace=`。
- `--filename` / `--patch-file` 只能寫占位(內容放 `manifest` / `patch` 欄位,才會被 plan sha256 涵蓋);寫實際路徑 → BLOCKED。
- 移除 allUsers / allAuthenticatedUsers 的還原指令會重新公開資料,計畫與變更紀錄會加 ⚠ 警示。
- 叢集的盤點檔以 `<位置>_<名稱>` 命名(`nodepools/asia-east1_prod.json`、`k8s/asia-east1_prod/`)。
- `kubectl apply`:`command` 寫 `["kubectl", "--context=…", "apply", "--filename=<manifest>"]`,YAML 全文放 `manifest`;`kubectl patch`:`--patch-file=<patch>`,內容放 `patch`。
- `precondition` / `expected` 不可指向可能含秘密的欄位(`/data`、`/stringData`、`/binaryData`、env `value`、`command` / `args`、annotations)。
- `precondition` / `expected`:`{"field": "/JSON pointer", "expect": 值}`,或 IAM 用 `{"binding_present"|"binding_absent": [成員, 角色]}`(只比對無條件綁定);JSON pointer 指向該 kind 的快照(下表);apply 的快照是 `{"objects": [每份文件的線上物件]}`,所以寫 `/objects/0/...`;resize 的快照是 `{"nodepool": …, "node_count_per_zone": n}`。`expected` 必填(rollout restart 除外,kit 自動驗 restartedAt)。
- plan.py 會自動加 `auto_pre`(還原指令依賴的原值),變更時一起比對。

## 變更允許清單(`rules/allow_change.json`)

| kind | 指令 | 快照 | 還原 |
|---|---|---|---|
| gke-cluster-update | `gcloud container clusters update` 只限:master authorized networks、shielded nodes、workload pool、network policy(授權網路原本已啟用且清單為空時判不可還原) | clusters describe | 反向旗標 / 原值 |
| gke-nodepool-update | `gcloud container node-pools update`:auto-upgrade / repair、workload-metadata、autoscaling | node-pools describe | 同上 |
| gke-resize | `gcloud container clusters resize --node-pool --num-nodes`(>0;已開 autoscaling 不可) | node pool + 各區 MIG targetSize(不一致判不可還原) | 原節點數 |
| firewall-update | `gcloud compute firewall-rules update`(只限 INGRESS allow 規則):source-ranges、rules、target-tags、disabled、logging、priority、description | describe | 原值 |
| bucket-update | `gcloud storage buckets update`:public access prevention、uniform access、versioning | describe | 反向旗標 |
| bucket-iam-remove | `gcloud storage buckets remove-iam-policy-binding` | get-iam-policy | add 回去 |
| project-iam-add / remove | `gcloud projects add/remove-iam-policy-binding` | get-iam-policy | 反向 |
| sql-patch | `gcloud sql instances patch`:`--ssl-mode`(不接受舊的 --require-ssl,它的還原無法回到原 sslMode)、授權網路、備份時間、PITR | describe | 原值 |
| kubectl-apply | 只能修改既有資源(diff 出現新建 → 不可還原) | 線上物件 | `kubectl replace -f before/C<n>.rollback.json` |
| kubectl-patch | deployment、statefulset、daemonset、cronjob、HPA、PDB、configmap | 線上物件 | 同上 |
| kubectl-scale / rollout-restart / label-namespace(只限 pod-security 標籤) | | 線上物件 | 原 replicas / 不需 / 原 label |

- **共同禁止**:任何 delete / `set-iam-policy` / `services disable` / upgrade / `--cluster-version` / `--release-channel` / `--node-version` / `--image-type`;新增 allUsers / allAuthenticatedUsers;任何 `0.0.0.0/0`、`::/0`;防火牆 `all` 或 1–65535 全埠;動 gcp-guardian 自己的 SA;新增 / 移除 `roles/owner`;停用 GKE / IAP 防火牆規則;`--prune`、`--force`、kustomize apply;retention 設定;建立 SA 金鑰。
- **反向旗標**(例 `--enable-shielded-nodes`)會先讀變更前狀態;已是目標狀態 → 判「不可還原」(其實不需變更,還原反而會改掉原設定),狀態記入 `auto_pre`。bucket / Cloud SQL 的狀態欄位讀不到也判不可還原。
- gcloud 規定要成對的旗標(`--master-authorized-networks` 要帶 `--enable-master-authorized-networks`、`--min/max-nodes` 要帶 `--enable-autoscaling`)缺一就 BLOCKED;已啟用時這個 enable 旗標當「陪同旗標」,還原時保留。
- 原本就對全網開放的防火牆規則:不可再擴大埠 / 套用對象或重新啟用(要先收緊來源)。已啟用 autoscaling 的 node pool 不可 resize(改用 --min/--max-nodes)。GKE 類變更逾時 4 小時(`GG_GKE_TIMEOUT`),逾時記「狀態不明」。
- 防火牆 target-tags 清空 / 新增、priority 調高、Cloud SQL SSL 降級都標「放寬安全」;IAM member 一律小寫。
- YAML 審查的 kustomize 展開結果只存遮蔽後的 JSON(`inventory/rendered/*.json`);`--check` 不允許 inventory 有其他格式的檔案。
- 關閉功能的反向旗標會連同被清掉的設定一起還原(關授權網路 → 還原帶回原網段;關 autoscaling → 帶回 min / max)。
- bucket 變更先確認 bucket 在本專案的 `buckets list` 裡;kubectl 與 resize 讀不到叢集 endpoint 一律 BLOCKED。
- 遮蔽另含容器 `command` / `args` 的密碼類參數值、node pool `config.metadata` 的值。
- 清空防火牆 `--source-ranges` 一律禁止(等於全開);Pod Security 任何 `-version` 變更或等級下降標放寬。
- YAML 合併鍵 `<<` 與別名一律拒絕(列無法判定),避免藏住設定。`render.mjs` 只寫 GG_REPORT_DIR 底下的 run 目錄。
- manifest / patch 含 `<redacted` 占位一律 BLOCKED(盤點是遮蔽過的,照抄會把真實值蓋掉:只寫要改的欄位)。系統 namespace(kube-system、gke-*…)一律不改。變更 KSA 的 `iam.gke.io/gcp-service-account` 視同高風險 → BLOCKED。
- 已有條目執行後,後面的條目被擋:整體狀態是 ISSUES(不是 BLOCKED)。收到 SIGTERM / SIGHUP / SIGINT 會先寫紀錄、清憑證;被 SIGKILL 留下的憑證快取下次執行時清掉(超過 6 小時)。collect / plan / change 請在背景執行(可能超過 10 分鐘)。
- gcloud update 一次只能改一類設定(`exclusive_groups`),多類請拆成多個 C 編號。
- 變更指令成功但之後的快照 / 驗證失敗:結果記「已執行(驗證失敗)」並附還原指令。
- GKE(clusters update / resize、node-pools update)與 Cloud SQL patch 執行時自動加 `--async`,由 kit 輪詢操作狀態(`operations describe`,每次輪詢前換 token)到 DONE 再驗證;gcloud 沒印操作時,用送出前與送出後 `operations list` 的差集找自己的操作(不依賴時鐘;targetLink 對到叢集或該 node pool、排除 AUTO_*、SQL 只接受 UPDATE、排除已追蹤過的;連續兩次都是同一筆唯一新操作才採用,多筆即狀態不明);找不到、連續 10 分鐘查不到狀態(權限不足 / 找不到則立即)、逾時(GKE 4 小時、SQL 1 小時)或輪詢出錯,一律記「狀態不明」並附還原指令。計畫裡不可自己寫 `--async` / `--format`。
- 新值等於現值的條目判「不需變更」→ BLOCKED(避免空操作被記成修正)。
- kubectl scale 縮到 0 一律禁止(會停止服務)。`GG_REPORT_DIR` 不可含空白。
- IAM 增減(含 bucket 移除)必帶 `--condition=None`(帶條件的綁定請使用者自己處理);綁定比對只看無條件綁定,同名的帶條件綁定不受影響。
- YAML 審查:kustomization 引用遠端 base(https / git / github.com…)時不展開(不連網),列無法判定。
- kubectl apply / patch 只允許 workload 類(deployment、statefulset、daemonset、cronjob、HPA、PDB、configmap);NetworkPolicy、Ingress、Service、ServiceAccount 等網路與身分資源的語意放寬無法可靠判斷,請使用者自己改;workload 改 `serviceAccountName` 視同高風險 → BLOCKED;namespace label 只允許 `pod-security.kubernetes.io/*`;防火牆單一範圍或同協定合計超過 1000 個埠視同全開;Secret、RBAC、webhook、CRD、Namespace 等在快照之前就擋;patch 的資源種類一律小寫。
- `0.0.0.0/0` / `::/0` 以 ipaddress 解析判斷(`0::/0`、多段合起來涵蓋全部也擋)。
- **沒有還原範本的旗標**(例 `--security-posture`、`--maintenance-window-*`)一律判「不可還原」→ BLOCKED,請使用者自己做。
- **放寬安全**(`loosens_security`)由固定規則判斷:新增高權角色、關閉公開存取防護 / 統一存取 / 版本、放寬授權網路或防火牆、Pod Security 降級、apply 後出現新的「中」問題。apply / patch 後出現新的「嚴重 / 高」問題 → BLOCKED。

## 隔離與安全

- 每個 run 自己的 `CLOUDSDK_CONFIG=<run>/gcloud`、`KUBECONFIG=<run>/gcloud/kubeconfig`、`HOME=<run>/gcloud/home`(kubectl 與 auth plugin 的快取),結束刪除;`commands.log` 記錄每個指令(金鑰路徑以 `<key>` 代替)。
- 唯讀:`rules/allow_read.txt`(審查)、`rules/allow_dryrun.txt`(計畫 / 變更前快照與 dry-run),先過 `rules/deny_read.txt`(Secret 值、序列埠、`--raw`、exec、token…)。
- 遮蔽值寫成 `<redacted len=N>`(不附雜湊,避免離線猜密碼)。resize 的驗證會等新節點加入(最多 `GG_VERIFY_WAIT` 秒,預設 600)。
- 遮蔽(寫檔前):Secret `data`、ConfigMap 值、env `value`(另標 `looks_secret`)、VM metadata 值(布林設定保留)、`masterAuth.*`、last-applied annotation、秘密樣式(`rules/secret_patterns.json`)。
- plan.json 只保留 `kubectl diff` 的「資源 + 新建 / 修改」摘要,不留 diff 內容。
- `before/C<n>.rollback.json` 是 kubectl 還原用的**原始物件**(還原指令就指向它)(ConfigMap 可能含原值),權限 600,`--check` 不掃它;報告與回報不印它的內容。
- 專案鎖:`<GG_REPORT_DIR>/<專案>/.lock` 的 `fcntl.flock`(plan build、change 期間;程序結束或當掉即釋放);被佔用 → BLOCKED。
- `guard.py`:gcp-guardian agent 的 PreToolUse hook。Bash 只准「單一入口腳本 + 參數」或不遞迴的唯讀指令(ls(不帶 -R / -L)、cat、head、tail、wc、shasum、stat、date、pwd;grep / find / diff 一律不放行,搜尋用 Grep / Glob 工具),禁止 `; & | $ ` < > ( ) * ? [ ] { } ~ ! #` 與換行;不可直接執行 gcloud / kubectl / curl…;參數(含 `--opt=值`、黏著旗標的值,大小寫不分)不可指向受保護路徑;`*.rollback.json` 不可讀;Read 不可碰、Grep / Glob 的搜尋範圍不可包含 `~/.config/gcp-guardian`、金鑰、`~/.config/gcloud`、`~/.kube`、run 內憑證(報告目錄裡有執行中 run 的憑證或 rollback 檔時,搜尋整個報告目錄也會被擋);Write / Edit 只准 run 目錄的 `manual.json`、`plan.input.json`(**不能寫 approval.json**)。hook 每次執行前會先清掉已死程序留下的憑證快取。受保護判斷同時比對檔案 inode(擋 `/System/Volumes/Data/...` 等別名路徑),並保護環境變數 `CLOUDSDK_CONFIG`、`KUBECONFIG`、`GOOGLE_APPLICATION_CREDENTIALS` 指向的檔案。測試:`python3 <kit>/scripts/guard.py --test '<指令>'`。

## 已知限制

- 只在 kit 自己的程式裡強制;其他工具(例如沒有掛 hook 的 agent 或 Codex)若直接用金鑰呼叫 gcloud,kit 擋不到。
- CIS 編號只標有把握的 GCP Foundations v3.0.0 項目;GKE 規則未標 CIS 編號。
- 真實 GCP 專案的端到端測試要使用者提供測試專案;selftest 只驗證到假 gcloud / kubectl。
- 多叢集專案:stub 只模擬單一叢集;真實 kubeconfig 會累積多個 context(由 get-credentials 處理)。
