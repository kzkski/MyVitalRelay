# Garmin Sync 運用ガイド

関連: `docs/claude-garmin-access.md`, `docs/garmin-api-sync-investigation.md`

---

## 1. Secrets

### GitHub Actions

| Secret | 内容 |
|---|---|
| `GARMIN_SYNC_USERS` | `[{"supabase_user_id":"uuid","email":"...","password":"..."}]` |
| `SUPABASE_URL` | `https://xxx.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Sync Job 専用（Storage upload + queue UPDATE） |
| `GARMIN_BACKFILL_USER_ID` | バックフィル対象の `auth.users` UUID |

### Supabase Edge Function（`garmin-sync-dispatch`）

| Secret | 内容 |
|---|---|
| `GITHUB_DISPATCH_TOKEN` | GitHub PAT（Fine-grained: **Contents: Read and write** / Classic: `repo`） |
| `GITHUB_REPO` | 省略可。デフォルト `kzkski/MyVitalRelay` |
| `GARMIN_WEBHOOK_SECRET` | pg_net トリガー → Edge Function 認証用（Vault と同値） |

**トークン永続化:** 初回 login 後 `garmin_oauth_tokens` に DI token を保存。以降は password 再ログインを避ける。

---

## 2. ジョブ実行フロー

1. `reset_stale_garmin_sync_requests(30)` — stuck `running` を復旧
2. `pending` を 1 件 claim（`status=running`, `started_at=now()`）
3. Garmin login（token 読込 → 失敗時のみ password）
4. `scope` に応じて同期:
   - `activities`: 期間内 activity（`sync_status=complete` はスキップ）+ FIT + API
   - `daily`: 期間内の各日（日次 API 全件）
   - `all`: 両方
5. `link_garmin_activity_training_log(user_id)`（activities 含む場合）
6. `progress` JSON を記録し、`complete` / `partial` / `failed` に更新

**`complete` でも activity 0 件の場合は `partial` になる**（空振り検知）。

### GHA concurrency

```yaml
concurrency:
  group: garmin-sync
  cancel-in-progress: false
```

---

## 3. JSONB / Storage 閾値

**暫定:** 512KB 超 → `garmin-json` バケットへ退避、DB には `_storage_path` のみ。

| 列 | インライン | Storage |
|---|---|---|
| `fit_parsed` | ≤ 512KB | `fit_parsed_storage_path` |
| `api_responses` | ≤ 512KB | `api_json_storage_path` |
| FIT zip | — | `fit_storage_path`（常に Storage） |

---

## 4. トリガーとレイテンシ

| 経路 | レイテンシ | 備考 |
|---|---|---|
| HealthKit → `garmin_sync_request` INSERT → **pg_net トリガー** → GitHub | 数十秒〜2分 | **主経路** |
| Claude → INSERT → 同上 | 同上 | `trigger_source=claude` |
| **Garmin Sync 手動 Run** | 即時 | デバッグ・フォールバック |
| **Garmin Backfill workflow** | キュー投入 + 同一 run で drain | Webhook 対象外（`trigger_source=manual`） |

```
HealthKit / Claude
       │
       ▼
garmin_sync_request INSERT (pending)
       │
       ▼
pg_net DB トリガー (notify_garmin_sync_dispatch)
       │
       ▼
Edge Function: garmin-sync-dispatch
       │
       ▼
GitHub repository_dispatch (event: garmin-sync)
       │
       ▼
Garmin Sync workflow → garmin_sync_job.py
```

**cron schedule は廃止**（GitHub 側の schedule 登録不具合のため）。Dashboard Database Webhook の手動設定も不要（pg_net トリガーで代替）。

---

## 5. Webhook セットアップ

**本番は pg_net トリガー（マイグレーション適用済み）で自動キック。** Dashboard Webhook の手動設定は不要。

```
garmin_sync_request INSERT (healthkit/claude, pending)
       │
       ▼
pg_net trigger → Edge Function (garmin-sync-dispatch)
       │
       ▼
GitHub repository_dispatch → Garmin Sync workflow
```

### 5.1 GitHub PAT（`GITHUB_DISPATCH_TOKEN`）

Edge Function が GitHub API を叩くための PAT。**専用トークンを推奨**（`gh auth token` はセッション依存で失効しうる）。

1. GitHub → Settings → Developer settings → Personal access tokens
2. **Fine-grained** 推奨: リポジトリ `MyVitalRelay` に **Contents: Read and write**（Metadata: Read は自動付与）
3. または Classic: **`repo` スコープ**（`public_repo` でも可 — 公開リポジトリのため）

> **注意:** `Actions: Read and write` だけでは `repository_dispatch` は **403** になる。必要なのは **Contents** 権限。

```bash
supabase secrets set GITHUB_DISPATCH_TOKEN="ghp_..." --project-ref ykcbevvorckcigwwtftw
```

動作確認（任意）:

```bash
curl -X POST \
  -H "Authorization: Bearer $GITHUB_DISPATCH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/kzkski/MyVitalRelay/dispatches \
  -d '{"event_type":"garmin-sync","client_payload":{"request_id":""}}'
```

HTTP 204 が返れば OK。

### 5.2 Edge Function シークレット

| Secret | 用途 |
|---|---|
| `GITHUB_DISPATCH_TOKEN` | GitHub `repository_dispatch` |
| `GARMIN_WEBHOOK_SECRET` | pg_net トリガー → Edge Function 認証 |
| `GITHUB_REPO` | 省略可（デフォルト `kzkski/MyVitalRelay`） |

`GARMIN_WEBHOOK_SECRET` は Supabase Vault の `garmin_webhook_secret` と **同じ値** にする（トリガーが Vault から読み取る）。

```bash
openssl rand -hex 24   # 新規作成時

supabase secrets set \
  GITHUB_DISPATCH_TOKEN="ghp_..." \
  GARMIN_WEBHOOK_SECRET="..." \
  --project-ref ykcbevvorckcigwwtftw

# Vault（SQL / Dashboard SQL Editor）
SELECT vault.create_secret('<same-secret>', 'garmin_webhook_secret', 'Auth for garmin-sync-dispatch', NULL);
```

Edge Function デプロイ:

```bash
supabase functions deploy garmin-sync-dispatch --project-ref ykcbevvorckcigwwtftw
```

### 5.3 DB トリガー（マイグレーション）

`supabase/migrations/20260713120000_garmin_sync_webhook_trigger.sql` が以下を作成:

- `notify_garmin_sync_dispatch()` — `pg_net.http_post` で Edge Function を呼ぶ
- `garmin_sync_request_notify_dispatch` — INSERT 後に発火

**フィルタ:** `status=pending` かつ `trigger_source ∈ {healthkit, claude}` のみ dispatch。バックフィル（`manual`）は Garmin Backfill workflow が同一 run 内で drain。

### 5.4 動作確認

1. テスト INSERT:

```sql
INSERT INTO garmin_sync_request (user_id, scope, date_from, date_to, trigger_source)
VALUES (
  '77ea5bd6-e655-4f45-8143-40777562ace1',
  'activities',
  CURRENT_DATE - 7,
  CURRENT_DATE,
  'claude'
);
```

2. GitHub Actions → **Garmin Sync** に `repository_dispatch` 実行が現れる（数十秒以内）
3. Edge Function ログ: Dashboard → Edge Functions → garmin-sync-dispatch → Logs

---

## 6. 90 日バックフィル（Phase 2）

GitHub Actions → **Garmin Backfill** → Run workflow

| 入力 | デフォルト |
|---|---|
| days | 90 |
| chunk_days | 14 |
| scope | activities |

1. `garmin_sync_request` を chunk 単位で INSERT（`trigger_source=manual`）
2. 同一 workflow の sync job が pending をすべて処理（Webhook は発火しない）

ローカル:

```bash
export SUPABASE_URL=...
export SUPABASE_SERVICE_ROLE_KEY=...
export GARMIN_BACKFILL_USER_ID=77ea5bd6-...
export GARMIN_BACKFILL_DAYS=90
export GARMIN_BACKFILL_SCOPE=all
PYTHONPATH=scripts python scripts/garmin_backfill.py
# 続けて Garmin Sync workflow を手動実行
```

---

## 7. pending 滞留

- 24 時間以上 `pending` → `expire_old_pending_garmin_sync_requests` が `failed` に更新
- iOS 重複 INSERT は UNIQUE で弾かれ、ログは debug レベル
- Webhook / dispatch 失敗時は **Garmin Sync 手動 Run** で pending 全件を drain 可能

---

## 8. 実装済みスコープ

| 含む | 備考 |
|---|---|
| `scope=activities` / `daily` / `all` | |
| FIT + API + parse + link | |
| 日次 API 全件 → `garmin_daily_archive` | |
| 90 日バックフィル workflow | |
| `progress` + 空振り `partial` 判定 | |
| **Supabase pg_net トリガー → GitHub dispatch** | Edge Function `garmin-sync-dispatch` |
