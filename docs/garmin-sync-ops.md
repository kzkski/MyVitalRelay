# Garmin Sync 運用ガイド

関連: `docs/claude-garmin-access.md`, `docs/garmin-api-sync-investigation.md`

---

## 1. Secrets（GitHub Actions）

| Secret | 内容 |
|---|---|
| `GARMIN_SYNC_USERS` | `[{"supabase_user_id":"uuid","email":"...","password":"..."}]` |
| `SUPABASE_URL` | `https://xxx.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Sync Job 専用（Storage upload + queue UPDATE） |
| `GITHUB_DISPATCH_TOKEN` | Supabase Webhook → `repository_dispatch` 用（Phase 1.5） |

**トークン永続化:** 初回 login 後 `garmin_oauth_tokens` に DI token を保存。以降は password 再ログインを避ける。

---

## 2. ジョブ実行フロー

1. `reset_stale_garmin_sync_requests(30)` — stuck `running` を復旧
2. `pending` を 1 件 claim（`status=running`, `started_at=now()`）
3. Garmin login（token 読込 → 失敗時のみ password）
4. 期間内 activity を取得（`sync_status=complete` はスキップ）
5. 各 activity: API 全件 + FIT ORIGINAL → JSONB or Storage
6. `link_garmin_activity_training_log(user_id)`
7. request を `complete` / `partial` / `failed` に更新

### Claim（Python 側）

```python
# UPDATE ... WHERE id = ? AND status = 'pending' RETURNING *
# 0 rows → 他ワーカーが取得済み
```

### GHA concurrency

```yaml
concurrency:
  group: garmin-sync
  cancel-in-progress: false
```

---

## 3. JSONB / Storage 閾値

Phase 0 で `garmin_export_samples.py` の出力サイズを計測して決定。

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
| HealthKit → queue INSERT → **cron 10分** | 最大 10 分 |
| Supabase Webhook → `repository_dispatch` | 数十秒〜数分（Phase 1.5） |
| Claude 手動 INSERT | 同上 |

**Claude への指示:** Webhook 未設定時は「最大 10 分待つ」と明記。2〜3 分とは言わない。

---

## 5. Webhook 設定（Phase 1.5）

1. Supabase Dashboard → Database Webhooks
2. Table: `garmin_sync_request`, Event: INSERT
3. Filter: `trigger_source=eq.healthkit`
4. URL: `POST https://api.github.com/repos/kzkski/MyVitalRelay/dispatches`
5. Body: `{"event_type":"garmin-sync","client_payload":{"request_id":"{{ record.id }}"}}`
6. Header: `Authorization: Bearer {GITHUB_DISPATCH_TOKEN}`

Workflow は `github.event.client_payload.request_id` を `REQUEST_ID` に渡す。

---

## 6. pending 滞留

- 24 時間以上 `pending` → ジョブが `failed` に更新（要 job 実装）
- iOS 重複 INSERT は UNIQUE で弾かれ、ログは debug レベル

---

## 7. Phase 1 スコープ

| 含む | 含まない |
|---|---|
| `scope=activities` のみ | `daily` / `all` |
| FIT + API + parse + link | ketolog ガイド追記 |
| cron + workflow_dispatch | Webhook（1.5） |
