# Intervals.icu Wellness 同期 運用ガイド

関連: GitHub Issue #24、`docs/garmin-sync-ops.md`（参考パターン）

体重・体脂肪を `body_composition_sample` → Intervals.icu wellness へ一方向 PUSH する。
ホットパスは **Edge Function が直接 claim + PUT**（GitHub Actions は経由しない）。

---

## 1. Secrets

### Supabase Edge Function（`interval-icu-sync`）— 一次情報源

| Secret | 内容 |
|---|---|
| `INTERVAL_ICU_SYNC_USERS` | `[{"supabase_user_id":"uuid","api_key":"...","athlete_id":"0"}]`（`athlete_id` 省略時は `"0"` = API Key 本人） |
| `INTERVAL_ICU_WEBHOOK_SECRET` | pg_net / Drain からの呼び出し認証（`openssl rand -hex 24`） |

`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` は Edge Function に自動注入される。

### GitHub Actions（バックフィル / Drain）

| Secret | 内容 |
|---|---|
| `INTERVAL_ICU_SYNC_USERS` | **EF と同値を複製**（Backfill 専用。値変更時は両方更新） |
| `INTERVAL_ICU_BACKFILL_USER_ID` | 複数ユーザー時のみ。単一ユーザーなら省略可 |
| `INTERVAL_ICU_WEBHOOK_SECRET` | Drain 用（EF / Vault と同値） |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | 既存を流用 |

### Vault

| Name | 用途 |
|---|---|
| `interval_icu_webhook_secret` | DB トリガー → EF の `X-Interval-Icu-Webhook-Secret` |

**API Key は DB テーブルに保存しない。** iOS アプリにも埋め込まない。

---

## 2. アーキテクチャ概要（Garmin との違い）

| | Garmin | Intervals.icu |
|---|---|---|
| ホットパス | EF → `repository_dispatch` → GHA → Python | **EF が直接 PUT** |
| 確認先 | GitHub Actions ログ | **Supabase Dashboard → Edge Functions → Logs** |
| GHA の役割 | 同期そのもの | バックフィル / 手動 Drain のみ |

```
HealthKit → iOS SyncEngine
  → body_composition_sample upsert
  → interval_icu_sync_request INSERT (trigger_source=healthkit)
  → pg_net → interval-icu-sync
  → claim → PUT wellness/{date} {"weight","bodyFat"}
```

当日（Asia/Tokyo）の PUT のみ `?localDate=` を付与し、settings の「現在の体重」も更新する。
日次の代表値は **その日の最初の測定**（`measured_at` 最小）。体重と体脂肪は独立に選ぶ。
`source_bundle_id = com.garmin.connect.mobile`（Garmin Connect Mobile）は除外する（Issue #38）。
同日の後続測定は Intervals.icu 側の値を変えない（再 PUT しても同じ値に収束）。

---

## 3. 初回セットアップ

```bash
# 1) webhook secret
openssl rand -hex 24

# 2) Edge Function secrets
supabase secrets set \
  INTERVAL_ICU_SYNC_USERS='[{"supabase_user_id":"<uuid>","api_key":"<key>"}]' \
  INTERVAL_ICU_WEBHOOK_SECRET='<same-as-openssl>' \
  --project-ref ykcbevvorckcigwwtftw

# 3) Vault（SQL Editor）
SELECT vault.create_secret('<same-secret>', 'interval_icu_webhook_secret', 'Auth for interval-icu-sync', NULL);

# 4) マイグレーション適用（Prod DB Migration workflow または）
# supabase db push --db-url "$PROD_DATABASE_URL"

# 5) デプロイ（config.toml で verify_jwt=false）
supabase functions deploy interval-icu-sync --project-ref ykcbevvorckcigwwtftw
```

GitHub Actions Secrets に `INTERVAL_ICU_SYNC_USERS` / `INTERVAL_ICU_WEBHOOK_SECRET` も登録する。

---

## 4. 動作確認

```sql
INSERT INTO interval_icu_sync_request (user_id, date, trigger_source)
VALUES ('<uuid>', CURRENT_DATE, 'manual');
```

数秒以内に `status=complete` になり、Intervals.icu の当日 wellness に weight / bodyFat が反映されること。

手動 Drain:

GitHub Actions → **Interval.icu Drain** → Run workflow

---

## 5. バックフィル（初回のみ）

GitHub Actions → **Interval.icu Backfill** → Run workflow

- `body_composition_sample` 全履歴を日次集約（**各日の最初の** weight / bodyFat。`com.garmin.connect.mobile` は除外）して `wellness-bulk` へ一括 PUT
- **localDate は付けない**（過去日で settings 現在体重を汚染しない）
- 常時自動バックフィルはしない。再実行は必要なときだけ手動

---

## 6. トラブルシュート

| 症状 | 確認 |
|---|---|
| pending のまま | Vault secret 名、EF secrets、`verify_jwt=false`、EF Logs |
| `failed` + 401 | API Key / Basic Auth（username はリテラル `API_KEY`） |
| `partial` | その日の weight/bodyFat サンプルなし |
| stuck `running` | 次回 EF 呼び出しで `reset_stale_...`(15分) が復旧。または Drain |

---

## 7. 既知の制約

- GHA `schedule:` は使わない（本リポジトリの既知不具合）
- 体脂肪・体重以外の wellness フィールドは非対象
- Secrets が EF と GHA で二重管理（変更時は両方）
- `athlete_id` 省略時 `"0"`（API Key 本人）
