# Garmin 同期 — Mac 実機検証手順

Issue #15 の Garmin 同期を Mac + iPhone + Garmin で検証する手順。  
**Webhook 自動トリガー（Phase 1.5）以降は Step 7 が自動化される。**

---

## 前提

- Mac に Xcode / xcodegen
- iPhone 実機（HealthKit 実データ）
- Garmin Connect アカウント（MFA 無効）
- ケトログと同じ Supabase ユーザーでサインイン

---

## Step 0: リポジトリ取得

```bash
git fetch origin
git checkout main
cd MyVitalRelay
xcodegen generate
open MyVitalRelay.xcodeproj
```

---

## Step 1: DB マイグレーション適用

**方法 A（推奨）:** main マージ後に GitHub Actions `Prod DB Migration` を実行。

**方法 B（手動）:**

```bash
# Supabase CLI + PROD_DATABASE_URL が必要
supabase db push --db-url "$PROD_DATABASE_URL"
```

適用後、Dashboard で以下が存在することを確認:

- テーブル: `garmin_sync_request`, `garmin_activity_archive`, `garmin_daily_archive`, `garmin_oauth_tokens`
- View: `garmin_activity_claude_summary`, `garmin_daily_summary`, `garmin_daily_claude`
- Storage バケット: `garmin-fit`, `garmin-json`
- トリガー: `garmin_sync_request_notify_dispatch`（Webhook 用）
- Edge Function: `garmin-sync-dispatch`

---

## Step 2: Secrets 設定

### GitHub Actions（リポジトリ Settings → Secrets → Actions）

| Secret | 値 |
|---|---|
| `GARMIN_SYNC_USERS` | `[{"supabase_user_id":"<auth.usersのuuid>","email":"...","password":"..."}]` |
| `SUPABASE_URL` | `https://ykcbevvorckcigwwtftw.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Dashboard → Settings → API |
| `GARMIN_BACKFILL_USER_ID` | バックフィル用 UUID |
| `PROD_DATABASE_URL` | Prod DB Migration 用（未設定なら Step 1 は手動） |

### Supabase Edge Function（`docs/garmin-sync-ops.md` §5 参照）

| Secret | 値 |
|---|---|
| `GITHUB_DISPATCH_TOKEN` | Fine-grained PAT: **Contents: Read and write** |
| `GARMIN_WEBHOOK_SECRET` | Vault `garmin_webhook_secret` と同値 |

`supabase_user_id` は Supabase Dashboard → Authentication → Users で確認。

---

## Step 3: Phase 0 — Garmin API 接続確認（Mac ターミナル）

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install garminconnect curl_cffi fitparse
export GARMIN_EMAIL='...'
export GARMIN_PASSWORD='...'
python scripts/garmin_export_samples.py
```

確認:

- [ ] `ログイン成功` と表示される
- [ ] `activities/*/*.zip` に FIT が保存される
- [ ] `manifest.json` の `activity_count` > 0

出力は `garmin_export_samples/`（gitignore 済み）。サイズをメモ（512KB 閾値の参考）。

---

## Step 4: Python 単体テスト（Mac / Linux 可）

```bash
python tests/test_garmin_sync_lib.py
```

すべて PASS すること。

---

## Step 5: iOS 単体テスト（Mac）

```bash
xcodebuild test -scheme MyVitalRelay \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

`GarminSyncRequestRecordTests` を含む全テストが PASS。

---

## Step 6: 実機ビルド + HealthKit キュー投入

1. iPhone 実機で Run
2. Google サインイン + HealthKit 許可
3. 「今すぐ同期」を実行（Garmin ワークアウトが HK にあること）

Supabase SQL Editor で確認:

```sql
SELECT id, trigger_source, scope, date_from, date_to, status, requested_at
FROM garmin_sync_request
ORDER BY requested_at DESC
LIMIT 5;
```

期待:

- [ ] `trigger_source = 'healthkit'`
- [ ] `scope = 'activities'`
- [ ] `status = 'pending'`（ジョブ未実行時）

`training_log` も従来通り upsert されていること。

---

## Step 7: Sync Job 実行確認

**通常（Webhook 有効時）:** Step 6 の INSERT 後、数十秒〜2分で自動実行。GitHub Actions → **Garmin Sync** に `repository_dispatch` が現れる。

**フォールバック:** Actions → **Garmin Sync** → **Run workflow**（手動）

数分後:

```sql
SELECT status, error_message, completed_at
FROM garmin_sync_request
ORDER BY requested_at DESC LIMIT 1;

SELECT garmin_activity_id, activity_name, sync_status, training_log_id, synced_at
FROM garmin_activity_archive
ORDER BY synced_at DESC LIMIT 5;
```

期待:

- [ ] request が `complete` または `partial`
- [ ] `garmin_activity_archive` に行が増える
- [ ] `fit_storage_path` が NULL でない
- [ ] `training_log_id` がリンクされている（時刻が近い Garmin ワークアウト）

---

## Step 8: Claude 読取確認（任意）

ケトログ Claude 連携の refresh_token で:

```bash
# access_token 取得後
curl "${SUPABASE_URL}/rest/v1/garmin_activity_claude_summary?select=activity_name,cadence_spm,training_log_id&limit=3" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}"
```

---

## トラブルシュート

| 症状 | 対処 |
|---|---|
| `garmin_sync_request` に行が無い | マイグレーション未適用、または Garmin 以外のワークアウトのみ |
| INSERT 失敗（iOS） | Xcode Console で `GarminSync` ログを確認 |
| request が `pending` のまま | Webhook / PAT 障害。`GITHUB_DISPATCH_TOKEN`（Supabase Secrets）と Edge Function ログを確認。手動 Run で drain 可 |
| request が `failed` | Actions ログ確認。`GARMIN_SYNC_USERS` の user_id 不一致 |
| `training_log_id` NULL | 開始時刻のずれ。`start_time` と archive の `start_time_local` を比較 |
| FIT download 403 | 非公開 activity。`sync_status=partial` は許容 |

---

## 完了条件

- [ ] Step 3〜7 すべて PASS
- [ ] HealthKit 同期 → キュー → Webhook → Sync Job → archive の縦切りが通る

Phase 1.5（日次 sync + pg_net Webhook）・Phase 2（90 日バックフィル）は実装済み。運用は `docs/garmin-sync-ops.md` を参照。
