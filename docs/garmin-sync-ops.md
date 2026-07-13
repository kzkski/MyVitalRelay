# Garmin Sync 運用ガイド

関連: `docs/claude-garmin-access.md`, `docs/garmin-api-sync-investigation.md`

---

## 1. Secrets（GitHub Actions）

| Secret | 内容 |
|---|---|
| `GARMIN_SYNC_USERS` | `[{"supabase_user_id":"uuid","email":"...","password":"..."}]` |
| `SUPABASE_URL` | `https://xxx.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Sync Job 専用（Storage upload + queue UPDATE） |
| `GARMIN_BACKFILL_USER_ID` | バックフィル対象の `auth.users` UUID |
| `GITHUB_DISPATCH_TOKEN` | Supabase Webhook 用（**後回し**） |

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

| 経路 | レイテンシ |
|---|---|
| HealthKit → queue INSERT → **Garmin Sync 手動 Run** | 即時〜1分 |
| cron（Garmin Sync schedule） | ベストエフォート（非信頼） |
| **Garmin Backfill workflow** | キュー投入 + 同一 run で drain |
| Supabase Webhook（**後回し**） | 数十秒〜数分 |

---

## 5. Webhook 設定（後回し）

Supabase Database Webhook → GitHub `repository_dispatch`。詳細は将来追加。

---

## 6. 90 日バックフィル（Phase 2）

GitHub Actions → **Garmin Backfill** → Run workflow

| 入力 | デフォルト |
|---|---|
| days | 90 |
| chunk_days | 14 |
| scope | activities |

1. `garmin_sync_request` を chunk 単位で INSERT
2. 同一 workflow の sync job が pending をすべて処理

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

---

## 8. 実装済みスコープ

| 含む | 後回し |
|---|---|
| `scope=activities` / `daily` / `all` | Supabase Webhook |
| FIT + API + parse + link | |
| 日次 API 全件 → `garmin_daily_archive` | |
| 90 日バックフィル workflow | |
| `progress` + 空振り `partial` 判定 | |
