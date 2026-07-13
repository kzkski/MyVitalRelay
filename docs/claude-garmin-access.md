# Claude 向け Garmin データアクセス設計

作成日: 2026-07-12  
前提: ケトログ Claude 連携（`refresh_token` → PostgREST + RLS）  
関連: `docs/garmin-api-sync-investigation.md`

---

## 1. 設計ゴール

| 要件 | 方針 |
|---|---|
| トリガーで取得 | Claude が **同期リクエストを発行** → ジョブが実行 → 完了後に読み取り |
| Claude から分析 | **Postgres JSONB + View**（FIT バイナリは Claude 非対応のため同期時に JSON 化） |
| 個人 1〜2 人 | 汎用 UI 不要。テーブル + ドキュメントで足りる |

---

## 2. Claude の既存アクセス経路（ketolog）

ケトログ v1.66+ の Claude 連携は **MCP ではなく Supabase REST** を直接叩く:

1. ketolog 設定画面で refresh_token を発行
2. `POST /auth/v1/token?grant_type=refresh_token` → access_token
3. `GET /rest/v1/{table}?select=...` + Bearer（RLS で本人データのみ）

既に Claude が読んでいる例:

```http
GET /rest/v1/training_log?select=*&date=gte.2026-07-01&order=start_time.desc
GET /rest/v1/food_log?select=*&date=eq.2026-07-10
```

Garmin 詳細も **同じ経路** で読めるようにする（新テーブル + View）。

---

## 3. 全体フロー

```
Garmin Watch → Garmin Connect → HealthKit
                                    │
                                    ▼
                          MyVitalRelay（ワークアウト検知）
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            training_log upsert          garmin_sync_request INSERT
            (概要データ)                    (trigger_source=healthkit)
                                                    │
Claude（会話中）──INSERT garmin_sync_request────────┤
(trigger_source=claude)                             │
                    │                               ▼
                    │                    Garmin Sync Job (Python)
                    │                    GHA: webhook即時 / cron 10分
                    │                               │
                    └────────SELECT─────────────────┤
                              garmin_activity_claude (VIEW)
```

### トリガー源（2 系統）

| トリガー | 発火元 | タイミング |
|---|---|---|
| **healthkit** | MyVitalRelay `SyncEngine` | Garmin ワークアウト upsert 直後 |
| **claude** | Claude 会話 | 分析前に不足データを補完 |

**ポイント:** iOS は Garmin 認証を持たない。`garmin_sync_request` への INSERT のみ。

### 即時実行（HealthKit 検知時）

INSERT 後 **数分待たず** FIT 取得を走らせるには、Supabase Database Webhook を設定:

1. `garmin_sync_request` INSERT（`trigger_source=healthkit`）を監視
2. GitHub `repository_dispatch` type `garmin-sync` を POST

→ Phase 1 実装時に Webhook 設定手順を README に記載。cron 10 分はフォールバック。

---

## 4. トリガー: `garmin_sync_request`

Claude が同期を **依頼するキュー**。

### 4.1 スキーマ

```sql
CREATE TABLE garmin_sync_request (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  scope text NOT NULL CHECK (scope IN ('activities', 'daily', 'all')),
  date_from date NOT NULL,
  date_to date NOT NULL,
  trigger_source text NOT NULL DEFAULT 'claude'
    CHECK (trigger_source IN ('healthkit', 'claude', 'manual')),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'complete', 'partial', 'failed')),
  progress jsonb NOT NULL DEFAULT '{}'::jsonb,
  error_message text,
  requested_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz
);
```

| trigger_source | 発火元 |
|---|---|
| `healthkit` | MyVitalRelay — Garmin ワークアウト upsert 後に自動 INSERT |
| `claude` | Claude 会話 — 分析前の手動依頼 |
| `manual` | デバッグ / workflow_dispatch |

### 4.2 Claude の操作例

**同期依頼（先週のアクティビティ）:**

```http
POST /rest/v1/garmin_sync_request
Content-Type: application/json
Prefer: return=representation

{
  "scope": "activities",
  "date_from": "2026-07-05",
  "date_to": "2026-07-11"
}
```

`user_id` は RLS / default trigger で自動付与（実装時に `auth.uid()` default または DB trigger）。

**進捗確認:**

```http
GET /rest/v1/garmin_sync_request?id=eq.{request_id}&select=id,status,progress,error_message,completed_at
```

**既存データ確認（同期不要か判断）:**

```http
GET /rest/v1/garmin_activity_archive?select=garmin_activity_id,synced_at&start_time_local=gte.2026-07-05T00:00:00+09:00&start_time_local=lte.2026-07-11T23:59:59+09:00
```

→ 期間内の activity が揃っていれば ① をスキップして ③ へ。

### 4.3 ジョブ側

| トリガー | 動作 |
|---|---|
| **cron 10分** | `status=pending` を 1 件ずつ `running` → 同期 → `complete` |
| **workflow_dispatch** | 手動 / Claude から即時実行（`request_id` 指定） |

---

## 5. Claude 向けデータ配置

### 5.1 原則

| データ | 保存 | Claude が読む |
|---|---|---|
| FIT 原データ (.fit) | Supabase Storage（アーカイブ） | ❌ 直接不可 |
| FIT パース JSON | `garmin_activity_archive.fit_parsed` JSONB | ✅ |
| API 全レスポンス | `garmin_activity_archive.api_responses` JSONB | ✅ |
| 日次 API 全レスポンス | `garmin_daily_archive.api_responses` JSONB | ✅ |
| 分析用サマリー | View `garmin_activity_claude_summary` | ✅ 一覧・会話開始時 |
| 分析用詳細 | View `garmin_activity_claude` | ✅ 単一 activity 深掘り |

大型 JSON（512KB 超）は Storage 退避。View の `fit_parsed_in_storage` / `api_responses_in_storage` で判定。

同期ジョブ: `scripts/garmin_sync_job.py`。運用: `docs/garmin-sync-ops.md`。

### 5.2 `garmin_activity_archive`（Claude 読取対象）

```sql
CREATE TABLE garmin_activity_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  garmin_activity_id bigint NOT NULL,
  activity_type_key text,
  activity_name text,
  start_time_local timestamptz,
  duration_sec numeric,
  -- Claude 向け（PostgREST で直接 select 可能）
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,       -- get_activity の要約
  fit_parsed jsonb NOT NULL DEFAULT '{}'::jsonb,    -- FIT 全メッセージを JSON 化
  api_responses jsonb NOT NULL DEFAULT '{}'::jsonb, -- splits / zones / exercise_sets 等
  -- アーカイブ（Claude 非経由）
  fit_storage_path text,                            -- Storage 内 zip（原データ保全）
  training_log_id uuid REFERENCES training_log(id),
  sync_request_id uuid REFERENCES garmin_sync_request(id),
  sync_status text NOT NULL DEFAULT 'complete',
  synced_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id)
);
```

### 5.3 View: 2 段構成

**一覧・会話開始:** `garmin_activity_claude_summary`（軽量、JSONB なし）

```http
GET /rest/v1/garmin_activity_claude_summary?training_log_date=eq.2026-07-10&select=activity_name,cadence_spm,avg_power_w,training_log_id
```

**単一 activity 深掘り:** `garmin_activity_claude`（`garmin_activity_id` で絞る）

```http
GET /rest/v1/garmin_activity_claude?garmin_activity_id=eq.19876543210&select=activity_name,summary,fit_parsed,api_responses
```

PostgREST では `api_responses->get_activity_splits` のような JSON path フィルタは使えない。深掘り時は `api_responses` 列全体を select し、Claude が JSON 内を解析する。

### 5.4 日次: `garmin_daily_claude`

```sql
CREATE VIEW garmin_daily_claude
WITH (security_invoker = true)
AS
SELECT
  user_id,
  date,
  synced_at,
  api_responses->'get_training_readiness' AS training_readiness,
  api_responses->'get_hrv_data' AS hrv,
  api_responses->'get_body_battery' AS body_battery,
  api_responses->'get_sleep_data' AS sleep,
  api_responses
FROM garmin_daily_archive;
```

---

## 6. Claude の会話フロー（推奨プロンプト/手順）

### 6.1 ランニング詳細分析

1. `training_log` で対象セッション特定（`data_source=garmin`）
2. `garmin_activity_claude?training_log_id=eq.{id}` を確認
3. 無ければ `garmin_sync_request` を INSERT（`date_from`/`date_to` をその日 ±1 日）
4. `status=complete` までポーリング（**Webhook 未設定時は最大 10 分**。ユーザーに待機を伝える）
5. `api_responses->get_activity_splits` / `fit_parsed->laps` 等でラップ分析
6. `training_log.rpe` / `condition_notes` と Garmin 客観データを統合して回答

### 6.2 Training Readiness / 回復

1. `garmin_daily_claude?date=eq.2026-07-12`
2. 無ければ `garmin_sync_request` scope=`daily`
3. `training_readiness`, `hrv`, `body_battery` を解釈

---

## 7. FIT → JSON（Claude 向け変換）

同期ジョブ内で実施:

```python
import fitparse

def fit_to_json(fit_bytes: bytes) -> dict:
    fit = fitparse.FitFile(BytesIO(fit_bytes))
    messages = []
    for msg in fit.get_messages():
        messages.append({
            "name": msg.name,
            "fields": {f.name: f.value for f in msg.fields},
        })
    return {"messages": messages, "message_count": len(messages)}
```

- **全メッセージ保持**（ユーザー要件「FIT 全部」に対応）
- サイズが大きい場合: `fit_parsed` は Storage に退避し、View には `fit_parsed_storage_path` のみ（閾値 1MB 等）
- Claude 深掘り時: `GET ...&select=fit_parsed` または splits API 部分だけ select

---

## 8. 即時トリガー（オプション）

cron 10 分待ちが長い場合:

```yaml
# .github/workflows/garmin-sync.yml
on:
  workflow_dispatch:
    inputs:
      request_id:
        description: garmin_sync_request.id
        required: true
  schedule:
    - cron: '*/10 * * * *'  # pending キュー処理
```

Claude から即時 dispatch するには、将来 ketolog に薄いプロキシを追加:

```
POST /api/garmin-sync/trigger  { "request_id": "..." }
  → GitHub API workflow_dispatch（server-side PAT）
```

**Phase 1 では cron + 手動 dispatch で十分。** ketolog プロキシは Phase 2。

---

## 9. ケトログ Claude 連携ガイドへの追記案

`packages/domain/src/claude-integration.ts` の `buildClaudeIntegrationUsageGuide()` に追記:

- 利用可能テーブル: `garmin_sync_request`, `garmin_activity_claude`, `garmin_daily_claude`
- 同期依頼 → 待機 → 分析 の 3 ステップ
- `training_log` との JOIN 例

---

## 10. Phase 更新

| Phase | 内容 |
|---|---|
| **1** | DDL（request + archive + views）+ Sync Job + cron |
| **2** | FIT parse 込み + Storage アーカイブ |
| **3** | ketolog ガイド追記 + 即時 trigger API（任意） |
