# Garmin API 詳細データ同期 — 調査結果

作成日: 2026-07-12（更新: 2026-07-12）  
関連 Issue: [#15](https://github.com/kzkski/MyVitalRelay/issues/15)  
調査対象: [kzkski/python-garminconnect](https://github.com/kzkski/python-garminconnect)

---

## 0. オーナー判断（確定）

| 項目 | 決定 |
|---|---|
| MFA | **無効** → 完全自動同期が可能（email/password + DI OAuth refresh） |
| ユーザー数 | **個人利用**（最大 1〜2 人。汎用マルチテナント化はしない） |
| 欲しいデータ | **FIT ファイル全量** + **Garmin API から取得できるデータはすべて**（個別フィールド選定はしない） |
| MyVitalRelay（iOS） | **現状維持**（HealthKit リレーはそのまま） |
| 分析主体 | **Claude**（ケトログ Claude 連携 → PostgREST + RLS） |
| 取得タイミング | **オンデマンド** + **HealthKit 検知時自動**（MyVitalRelay → キュー投入） |

---

## 1. エグゼクティブサマリー

### 結論: **GO — 「Claude トリガー + JSON アーカイブ」方式**

HealthKit 同期（`training_log` 等）は概要データの**正**として維持。Garmin 詳細は **Claude が `garmin_sync_request` を INSERT してトリガー** → Python ジョブが FIT + API を取得 → **Postgres JSONB + View** に保存 → Claude が PostgREST で分析。

FIT バイナリは Storage に保全するが、**Claude は JSONB のみ読む**（同期時に FIT を JSON 化）。詳細は **`docs/claude-garmin-access.md`**。

**推奨方向性:**

| レイヤ | 役割 |
|---|---|
| MyVitalRelay（iOS） | HealthKit → Supabase（現状維持） |
| **Claude（会話）** | `garmin_sync_request` INSERT → `garmin_activity_claude` SELECT |
| Garmin Sync Job（Python） | pending キュー処理 + FIT/API 取得 |
| `training_log` | HK 正。Garmin とは参照リンクのみ |
| Supabase Storage | FIT zip 原データ（アーカイブ） |
| Postgres | `fit_parsed` + `api_responses` JSONB、Claude 用 View |

---

## 2. 現状アーキテクチャ（MyVitalRelay）

```
Garmin Watch → Garmin Connect App → HealthKit → MyVitalRelay → Supabase
```

| HealthKit | Supabase |
|---|---|
| HKWorkout | `training_log` |
| bodyMass / bodyFatPercentage | `body_composition_sample` |
| sleepAnalysis | `sleep_segment` |
| activeEnergy / basalEnergy | `daily_activity_summary` |

Garmin API 同期は **HealthKit 経路とは独立した第 2 パイプライン**として追加する。

---

## 3. なぜ FIT + 全 API か

HealthKit 経由では以下が欠落または NULL のまま:

- 秒単位のセンサー系列（HR / power / cadence / GPS 等）→ **FIT に含まれる**
- ラップ・筋トレセット・トレーニング効果の詳細 → FIT または activity 詳細 API
- 日次 HRV / Training Readiness / Body Battery → 日次 API

個別列へのマッピングを都度設計するより、**取得可能なものを lossless に保存**する方が:

- 将来の分析要件変更に強い
- 「取りこぼし」が起きない
- python-garminconnect の API 追加に追従しやすい（JSON にそのまま格納）

---

## 4. python-garminconnect 調査

### 4.1 フォーク状態

- `kzkski/python-garminconnect` ↔ upstream: **差分 0**（2026-07-12）
- 認証: mobile SSO → DI OAuth Bearer（`~/.garminconnect/garmin_tokens.json`）
- MFA 無効 → refresh token 自動更新で **無人 cron 運用可**

### 4.2 FIT 取得

```python
api.download_activity(activity_id, dl_fmt=Garmin.ActivityDownloadFormat.ORIGINAL)
```

- 戻り値: **bytes**（通常は `.zip`。中に `.fit` が入る）
- TCX / GPX / CSV も取得可能だが、**正は ORIGINAL（FIT ソース）**
- 403 等: 非公開アクティビティ・権限不足時（テストでも既知）

### 4.3 アクティビティ単位 — 取得対象（読み取り系すべて）

| API | 内容 |
|---|---|
| `get_activity` | サマリー（一覧レスポンスと同等） |
| `get_activity_details` | チャート系列・ポリライン（大型） |
| `get_activity_splits` | ラップ |
| `get_activity_typed_splits` | 型付きスプリット |
| `get_activity_split_summaries` | スプリット集計 |
| `get_activity_weather` | 天候 |
| `get_activity_hr_in_timezones` | HR ゾーン滞在 |
| `get_activity_power_in_timezones` | パワーゾーン滞在 |
| `get_activity_exercise_sets` | 筋トレセット |
| `get_activity_gear` | 使用ギア |
| `download_activity(ORIGINAL)` | **FIT zip** |

書き込み系（upload / delete / set_name 等）は **同期対象外**。

### 4.4 日次 — 取得対象（読み取り系すべて）

`demo.py` カテゴリ 2〜4, 6, 7, 0 等から **get_* 系を網羅**:

| API | 内容 |
|---|---|
| `get_stats` / `get_user_summary` | 日次サマリー |
| `get_sleep_data` | 睡眠（Garmin スコア・HRV 含む） |
| `get_hrv_data` | HRV |
| `get_training_readiness` | Training Readiness |
| `get_training_status` | Training Status |
| `get_body_battery` / `get_body_battery_events` | Body Battery |
| `get_stress_data` / `get_all_day_stress` | Stress |
| `get_heart_rates` / `get_resting_heart_rate` | 心拍 |
| `get_steps_data` / `get_daily_steps` | 歩数 |
| `get_respiration_data` / `get_spo2_data` | 呼吸 / SpO2 |
| `get_max_metrics` | VO2 Max 等 |
| `get_intensity_minutes_data` | 強度分数 |
| `get_running_tolerance` | Running Tolerance |
| `get_body_composition` / `get_stats_and_body` | 体組成 |
| `get_floors` / `get_hydration_data` 等 | その他利用可能な get_* |

エラー（204 / 404 / 非対応デバイス）は `{"_error": "..."}` として JSON に記録し、同期全体は継続。

---

## 5. 推奨アーキテクチャ

```
Garmin Watch → HealthKit → MyVitalRelay
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        training_log   garmin_sync_request   (既存 HK 同期)
                         (healthkit)
                              │
Claude ──INSERT (claude)──────┤
                              ▼
                    Garmin Sync Job → garmin_activity_archive
                              │
Claude ──SELECT garmin_activity_claude──┘
```

**Claude アクセス設計の詳細:** `docs/claude-garmin-access.md`

**MyVitalRelay フック:** `SyncEngine.syncWorkouts` — `data_source='garmin'` の upsert 成功後に `garmin_sync_request` を INSERT（`GarminSyncRequestEnqueuer`）。

### 5.1 なぜサーバー側 Python か

| 案 | 評価 |
|---|---|
| **A. サーバー側 Python バッチ** | ⭐ **採用** — ライブラリそのまま、FIT バイナリ処理、1〜2 ユーザー向け Secrets 管理 |
| B. Supabase Edge Function | ❌ Python 非対応 |
| C. iOS アプリ内連携 | ❌ 130+ API + FIT + 認証の Swift 移植 |
| D. フィールド backfill のみ | ❌ オーナー要件（全データ）と不一致 |

### 5.2 認証・ユーザー管理（1〜2 人限定）

```json
// GitHub Actions Secret: GARMIN_SYNC_USERS（例）
[
  {
    "supabase_user_id": "77ea5bd6-....",
    "email": "....",
    "password": "...."
  }
]
```

- トークンは Actions キャッシュ or Secret 更新（`garmin_tokens.json` 相当）
- **汎用 OAuth UI / ユーザー自助連携は作らない**
- 2 人目追加時は JSON に 1 エントリ追加のみ

### 5.3 `training_log` との関係

- **上書きしない**（`rpe` / `condition_notes` 等の保護方針を維持）
- `garmin_activity_archive.training_log_id` で**参照リンク**（時刻突合で後付け可）
- 突合キー案: `start_time` ±120s + `duration` ±120s + activity type

---

## 6. スキーマ案（ドラフト）

### 6.1 Supabase Storage バケット

| バケット | パス例 | 内容 |
|---|---|---|
| `garmin-fit` | `{user_id}/{garmin_activity_id}.zip` | FIT ORIGINAL |
| `garmin-json` | `{user_id}/activities/{garmin_activity_id}.json` | 全 API レスポンス（大型時） |
| `garmin-json` | `{user_id}/daily/{date}.json` | 日次全 API レスポンス |

バケットは private + RLS（`auth.uid()` = パス先頭 UUID）。

### 6.2 Postgres

```sql
-- アクティビティアーカイブ（1 Garmin activity = 1 行）
CREATE TABLE garmin_activity_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  garmin_activity_id bigint NOT NULL,
  activity_type_key text,
  activity_name text,
  start_time_local timestamptz,
  duration_sec numeric,
  fit_storage_path text NOT NULL,           -- Storage 内 zip パス
  api_json_storage_path text,               -- 大型 JSON の Storage パス（任意）
  api_responses jsonb DEFAULT '{}'::jsonb,  -- 小型レスポンスはインライン
  training_log_id uuid REFERENCES training_log(id),  -- 参照リンク（任意）
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete','partial','failed')),
  sync_errors jsonb DEFAULT '[]'::jsonb,
  synced_at timestamptz DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id)
);

-- 日次アーカイブ（1 日 = 1 行）
CREATE TABLE garmin_daily_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  api_json_storage_path text,
  api_responses jsonb DEFAULT '{}'::jsonb,
  sync_status text NOT NULL DEFAULT 'complete'
    CHECK (sync_status IN ('complete','partial','failed')),
  sync_errors jsonb DEFAULT '[]'::jsonb,
  synced_at timestamptz DEFAULT now(),
  UNIQUE (user_id, date)
);

CREATE INDEX idx_garmin_activity_archive_user_start
  ON garmin_activity_archive (user_id, start_time_local);
CREATE INDEX idx_garmin_daily_archive_user_date
  ON garmin_daily_archive (user_id, date);

ALTER TABLE garmin_activity_archive ENABLE ROW LEVEL SECURITY;
ALTER TABLE garmin_daily_archive ENABLE ROW LEVEL SECURITY;

CREATE POLICY garmin_activity_archive_owner ON garmin_activity_archive
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY garmin_daily_archive_owner ON garmin_daily_archive
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
```

**初期スコープ外:** ラップ正規化テーブル、FIT パース済み時系列テーブル（必要になったら v2）。

---

## 7. 同期ジョブ仕様（案）

### 7.1 アクティビティ同期

1. `get_activities_by_date(since, today)` で ID 列挙
2. `garmin_activity_archive` に未同期 ID をフィルタ
3. 各 ID について §4.3 の API をすべて呼ぶ
4. FIT ORIGINAL をダウンロード → Storage upload
5. API レスポンスを JSON 化 → 閾値（例: 1MB）超えたら Storage、以下は JSONB
6. 行 upsert（`user_id, garmin_activity_id`）

### 7.2 日次同期

1. 直近 N 日（初回は 90 日、以降 7 日ローリング等）
2. §4.4 の get_* をすべて呼ぶ
3. `garmin_daily_archive` に upsert

### 7.3 実行基盤

- **主トリガー:** Claude → `garmin_sync_request` INSERT（オンデマンド）
- **ジョブ起動:** GitHub Actions cron（10 分毎、pending 処理）+ `workflow_dispatch`（即時）
- Secrets: `GARMIN_SYNC_USERS`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`

---

## 8. フェーズ計画

| Phase | 内容 | 成果 |
|---|---|---|
| **0** | `garmin_export_samples.py` ローカル実行 | login / FIT / JSON サンプル |
| **1** | DDL（request + archive + Claude View）+ Sync Job | Claude が trigger → read 可能 |
| **2** | FIT parse + Storage アーカイブ + 日次 | 全データ網羅 |
| **3** | ketolog Claude ガイド追記 + 即時 trigger API（任意） | UX 改善 |

---

## 9. リスク

| リスク | 深刻度 | 対応 |
|---|---|---|
| 非公式 API 変更 | 中 | upstream 追従。失敗時も HK パイプラインは独立 |
| ToS | 中 | 自己データ・1〜2 人限定。README に disclaimer |
| Storage 容量 | 中 | FIT ~100KB〜数 MB/activity。個人利用なら問題小 |
| `get_activity_details` 大型 JSON | 低 | Storage 退避 |
| FIT download 403 | 低 | `sync_status='partial'` + エラー記録 |

MFA 無効 → **トークン失効リスクは低〜中**（refresh 自動更新）。

---

## 10. 残確認（Phase 0）

- [ ] ローカル `login()` 成功
- [ ] FIT ORIGINAL zip が取得できる activity タイプ（run / bike / strength）
- [ ] zip 内 `.fit` の存在確認
- [ ] `training_log` との時刻突合成功率
- [ ] **認証情報の置き場所** — GitHub Actions Secrets でよいか（未回答）

---

## 11. 参考

- Claude アクセス設計: `docs/claude-garmin-access.md`
- フォーク: https://github.com/kzkski/python-garminconnect
- Export スクリプト: `scripts/garmin_export_samples.py`
- DDL ドラフト: `supabase/migrations/20260712120000_garmin_sync_claude_access.sql`
- MyVitalRelay 実装計画: `docs/implementation-plan.md`
