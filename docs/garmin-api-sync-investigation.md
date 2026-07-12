# Garmin API 詳細データ同期 — 調査結果

作成日: 2026-07-12  
関連 Issue: [#15](https://github.com/kzkski/MyVitalRelay/issues/15)  
調査対象: [kzkski/python-garminconnect](https://github.com/kzkski/python-garminconnect)（upstream: [cyberjunky/python-garminconnect](https://github.com/cyberjunky/python-garminconnect)）

---

## 1. エグゼクティブサマリー

### 結論: **段階的 GO（Phase 1: サーバー側エンリッチメント PoC）**

HealthKit 経由の Garmin 同期は **セッション概要（距離・HR・標高・カロリー）** までは実用的だが、**cadence / power / ラップ / トレーニング効果 / 筋トレセット / 日次ウェルネス指標** は HealthKit に載らないか、Garmin Connect アプリの HK 書き込み仕様上 NULL のまま残る。

`python-garminconnect` はこれらを Garmin Connect 内部 API から取得可能。ライブラリは 2026 年上半期に認証方式を刷新（DI OAuth Bearer トークン）しており、upstream は活発にメンテされている。フォーク `kzkski/python-garminconnect` は upstream と同期済み（差分 0 コミット）。

**推奨方向性:**

| レイヤ | 役割 | 変更 |
|---|---|---|
| MyVitalRelay（iOS） | HealthKit → Supabase リレー | **現状維持**（変更最小） |
| Garmin Sync Job（新規） | python-garminconnect → Supabase エンリッチメント | **新規追加** |
| `training_log` | ワークアウト正 | HK 由来を正とし、Garmin API で **NULL 列の backfill** + `metadata.garmin_activity_id` |
| 新規テーブル | 詳細データ | ラップ・筋トレセット・日次ウェルネス |

iOS アプリ内 Garmin 連携（Swift 移植）や Supabase Edge Function（Python 非対応）は **初期段階では非推奨**。

---

## 2. 現状アーキテクチャ（MyVitalRelay）

```
Garmin Watch → Garmin Connect App → HealthKit → MyVitalRelay → Supabase
Life Fitness  → LF Connect App   → HealthKit ↗
```

同期対象テーブル:

| HealthKit | Supabase |
|---|---|
| HKWorkout | `training_log` |
| bodyMass / bodyFatPercentage | `body_composition_sample` |
| sleepAnalysis（asleep 系） | `sleep_segment` |
| activeEnergy / basalEnergy（日次） | `daily_activity_summary` |

`training_log` の論理キー: `(user_id, start_time, end_time, workout_type)` — Issue #8, #12 対応済み。

---

## 3. データギャップ分析

### 3.1 ワークアウト（`training_log` 列 vs Garmin API）

| 列 / 概念 | HealthKit（Garmin 由来） | Garmin API（`get_activity` / typed `Activity`） | ギャップ |
|---|---|---|---|
| start/end, duration | ✅ | ✅ `startTimeLocal`, `duration` | 小（タイムゾーン表記差） |
| distance_km | ✅ | ✅ `distance`（meters） | なし |
| calories_burned | ✅ | ✅ `calories` | なし |
| avg_hr / max_hr | ✅ | ✅ `averageHR`, `maxHR` | なし（HK でも取得可） |
| hr_zone_minutes | ✅（HK 心拍サンプル集計） | ✅ `get_activity_hr_in_timezones` | Garmin 側はデバイスゾーン定義の可能性 |
| elevation_gain_m | ✅ | ✅ `elevationGain` | なし |
| **cadence** | ❌ NULL | ✅ `averageRunningCadenceInStepsPerMinute` | **大** |
| **power_watts** | ❌ NULL | ✅ `avgPower`, `maxPower`, `normPower` | **大** |
| stroke_count | ✅（水泳） | △ 種目依存 | 要実データ確認 |
| ラップ / スプリット | ❌ | ✅ `get_activity_splits`, `splitSummaries` | **大** |
| トレーニング効果 | ❌ | ✅ `aerobicTrainingEffect`, `activityTrainingLoad` | **中** |
| ランニング力学 | ❌ | ✅ `avgVerticalOscillation`, `avgGroundContactTime`, `avgStrideLength` | **中**（分析用） |
| 筋トレセット | ❌ | ✅ `get_activity_exercise_sets` | **大** |
| GPS / FIT 生データ | ❌ | ✅ `get_activity_details`, `download_activity` | **将来**（容量・プライバシー） |

根拠: `garminconnect/typed.py` の `Activity` モデル、`docs/graphql_queries.txt` のサンプルレスポンス、`WorkoutSnapshot.swift` / `WorkoutMapper.swift` の HK 取得範囲。

### 3.2 日次データ

| 概念 | 現行（HK → Supabase） | Garmin API | ギャップ |
|---|---|---|---|
| active / basal calories | ✅ `daily_activity_summary` | ✅ `get_stats`（`activeKilocalories`, `bmrKilocalories`） | 重複（ソース差の照合は有用） |
| 睡眠セグメント | ✅ `sleep_segment` | ✅ `get_sleep_data`（スコア・ステージ秒数・睡眠 HRV） | Garmin スコア・HRV は HK に無い |
| HRV | ❌ | ✅ `get_hrv_data` | **中** |
| Training Readiness | ❌ | ✅ `get_training_readiness` | **中** |
| Body Battery / Stress | ❌ | ✅ `get_body_battery`, `get_stress_data` | **中** |
| VO2 Max / Fitness Age | ❌ | ✅ `get_max_metrics` | **低〜中** |
| 歩数 | ❌（未同期） | ✅ `get_stats.totalSteps` | 低 |

---

## 4. python-garminconnect 調査

### 4.1 フォーク状態

- `kzkski/python-garminconnect` ↔ `cyberjunky:master`: **ahead 0 / behind 0**（2026-07-12 時点）
- 最新コミット: DI OAuth 認証、typed Pydantic モデル、130+ API メソッド
- 依存: `pip install garminconnect curl_cffi`（TLS impersonation 用）

### 4.2 認証フロー（実装影響大）

1. 初回: メール/パスワード + **MFA（有効時）** → `~/.garminconnect/garmin_tokens.json`
2. 以降: DI OAuth トークン自動 refresh（refresh token 有効限り）
3. 失効時: 再ログイン（MFA 再入力の可能性）

**自動同期のボトルネック:** MFA 有効アカウントでは、完全无人同期は refresh token 失効まで依存。失効時は人手介入が必要。

### 4.3 主要 API エンドポイント（アクティビティ詳細）

| メソッド | 用途 | Supabase 想定先 |
|---|---|---|
| `get_activities_by_date(start, end)` | 日付範囲の一覧取得 | 同期対象の activity ID 列挙 |
| `get_activity(id)` | サマリー + 基本スプリット | `training_log` backfill |
| `get_activity_splits(id)` | ラップ詳細 | `garmin_activity_lap` |
| `get_activity_exercise_sets(id)` | 筋トレセット | `garmin_exercise_set` |
| `get_activity_hr_in_timezones(id)` | HR ゾーン | `metadata` or 専用列 |
| `get_activity_power_in_timezones(id)` | パワーゾーン | 同上 |
| `get_activity_details(id)` | チャート / ポリライン | 将来（blob / 別ストレージ） |
| `download_activity(id, FIT)` | FIT バイナリ | 将来 |

### 4.4 サンプルレスポンス（upstream ドキュメントより）

`docs/graphql_queries.txt` の running activity 例（抜粋）:

```json
{
  "activityId": 16204035614,
  "averageHR": 139.0,
  "maxHR": 164.0,
  "averageRunningCadenceInStepsPerMinute": 165.59,
  "avgPower": 388.0,
  "maxPower": 707.0,
  "normPower": 397.0,
  "aerobicTrainingEffect": 3.2,
  "activityTrainingLoad": 158.79,
  "lapCount": 36,
  "splitSummaries": [ { "splitType": "INTERVAL_ACTIVE", "distance": 10425.37, ... } ]
}
```

→ HealthKit 同期だけでは **cadence / power / training effect / laps** が Supabase に入らないことがコード上確認できる。

---

## 5. アーキテクチャ案の評価

| 案 | 評価 | 理由 |
|---|---|---|
| **A. サーバー側 Python バッチ** | ⭐ **推奨** | ライブラリをそのまま使える。iOS 変更不要。トークンを 1 箇所で管理 |
| **B. Supabase Edge Function** | ❌ 非推奨 | Python ライブラリ非互換。API 移植コストが PoC を大幅に超える |
| **C. iOS アプリ内 Garmin 連携** | ❌ 非推奨 | MFA UX、認証情報保管、130+ API の Swift 移植。MyVitalRelay の責務から逸脱 |
| **D. HK 正 + Garmin 補完** | ⭐ **A と組み合わせ** | 既存 `training_log` 冪等性・論理キーを維持。Garmin はエンリッチメント専用 |

### 推奨構成（Phase 1 PoC）

```
┌─────────────────┐     HealthKit      ┌──────────────┐
│  MyVitalRelay   │ ─────────────────► │  Supabase    │
│  (iOS, 現状維持) │                    │  training_log│
└─────────────────┘                    │  sleep_* ... │
                                       └──────▲───────┘
                                              │
┌─────────────────┐  python-garminconnect   │
│ Garmin Sync Job │ ──────────────────────────┘
│ (GitHub Actions │   upsert / backfill
│  or cron VM)    │
└─────────────────┘
```

**突合キー（案）:**

1. **Primary:** `training_log` の `(user_id, start_time, end_time, workout_type)` と Garmin `startTimeLocal` + `duration` + `activityType.typeKey` をマッピング
2. **Secondary:** 突合成功後 `metadata.garmin_activity_id` を保存し、以降は ID 直結
3. **許容誤差:** 開始時刻 ±120 秒、duration ±2 分（実データで調整）

---

## 6. スキーマ案（ドラフト）

### 6.1 既存 `training_log` への backfill（Garmin API 由来のみ更新）

| 列 | ソース |
|---|---|
| `cadence` | `averageRunningCadenceInStepsPerMinute`（run/walk） |
| `power_watts` | `avgPower`（bike/run 等） |
| `metadata.garmin_activity_id` | `activityId` |
| `metadata.garmin_*` | training effect, norm power, lap_count 等 |

**注意:** backfill は `data_source='garmin'` 行に限定。PostgREST upsert 時に `rpe` / `condition_notes` 等の追記列を上書きしない（現行 SyncEngine と同じ部分更新方針）。

### 6.2 新規テーブル（案）

```sql
-- ラップ / スプリット（1 activity × N laps）
CREATE TABLE garmin_activity_lap (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  garmin_activity_id bigint NOT NULL,
  lap_index integer NOT NULL,
  start_time timestamptz,
  duration_sec numeric,
  distance_m numeric,
  avg_hr numeric,
  max_hr numeric,
  avg_speed_mps numeric,
  elevation_gain_m numeric,
  split_type text,
  metadata jsonb DEFAULT '{}'::jsonb,
  synced_at timestamptz DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id, lap_index)
);

-- 筋トレセット
CREATE TABLE garmin_exercise_set (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  garmin_activity_id bigint NOT NULL,
  exercise_index integer NOT NULL,
  set_index integer NOT NULL,
  category text,
  exercise_name text,
  reps integer,
  weight_kg numeric,
  duration_sec numeric,
  metadata jsonb DEFAULT '{}'::jsonb,
  synced_at timestamptz DEFAULT now(),
  UNIQUE (user_id, garmin_activity_id, exercise_index, set_index)
);

-- 日次ウェルネス（Garmin 固有指標）
CREATE TABLE garmin_daily_wellness (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  date date NOT NULL,
  training_readiness_score integer,
  training_readiness_level text,
  hrv_weekly_avg numeric,
  hrv_status text,
  body_battery_high integer,
  body_battery_low integer,
  avg_stress_level integer,
  vo2_max numeric,
  metadata jsonb DEFAULT '{}'::jsonb,
  synced_at timestamptz DEFAULT now(),
  UNIQUE (user_id, date)
);
```

RLS: 既存テーブルと同様 `auth.uid() = user_id`。

---

## 7. リスクと mitigations

| リスク | 深刻度 | 対応 |
|---|---|---|
| **非公式 API** — Garmin 内部 API 変更 | 中 | upstream 追従（フォーク sync）。同期失敗時は HK データのみで継続 |
| **ToS** — 個人利用のスクレイピング相当 | 中 | 自己データのみ・単一ユーザー。公式 Developer Program は enterprise 向け。利用は自己責任で文書化 |
| **MFA / トークン失効** | 高 | refresh token 監視 + 失効時通知。初回/MFA は手動 `example.py` |
| **HealthKit との二重管理** | 中 | HK を正、Garmin は NULL 補完 + 詳細テーブルのみ。数値衝突時は HK 優先 |
| **同期遅延** | 低 | HK: イベント駆動。Garmin Job: 1日1〜4回 cron で十分 |
| **2026 年 auth 障害** | 低（回復済） | python-garminconnect は mobile SSO + DI OAuth に移行済み。PoC で login 確認必須 |

---

## 8. フェーズ提案

### Phase 0: 実データ取得（**要 Kazuki さん作業**）

`scripts/garmin_export_samples.py` をローカル実行し、サンプル JSON を取得（リポジトリにはコミットしない）。

### Phase 1: PoC（推奨スコープ）

- GitHub Actions scheduled workflow（1日1回）または手動 dispatch
- 直近 7 日の Garmin アクティビティ取得
- `training_log`（`data_source='garmin'`）と突合 → `cadence` / `power_watts` / `metadata.garmin_activity_id` backfill
- 成功/失敗を Slack or GitHub Actions summary で通知

### Phase 2: 詳細テーブル

- `garmin_activity_lap` / `garmin_exercise_set` 同期
- ケトログ AI 向け SQL View

### Phase 3: 日次ウェルネス

- `garmin_daily_wellness` 同期
- `daily_activity_summary` / `sleep_segment` とのソース比較 View

---

## 9. 未確認事項（実データ待ち）

以下は **Kazuki さんの Garmin アカウントで `garmin_export_samples.py` を実行** しないと確定できない:

- [ ] 実際の HK 同期済み `training_log` 行と Garmin API レスポンスの **突合成功率**
- [ ] 開始時刻のタイムゾーン差（`startTimeLocal` vs `start_time` UTC/JST）
- [ ] 筋トレアクティビティの `get_activity_exercise_sets` レスポンス形状
- [ ] ランニング vs サイクリング vs 筋トレで取得可能フィールドの差
- [ ] MFA 有無と refresh token の実際の寿命
- [ ] `login()` が現環境で成功するか（最新 auth 方式）

---

## 10. 判断に必要な質問（Issue #15 コメント用）

実装方向性を確定するため、以下への回答をお願いしたい:

1. **Garmin MFA** は有効か？（有効なら自動同期の運用フロー設計が変わる）
2. **最優先で欲しいデータ** はどれか？（例: cadence/power / ラップ / 筋トレセット / Training Readiness）
3. **認証情報の置き場所** — GitHub Actions Secrets / 自宅 Mac cron / 別 VPS のどれが許容できるか
4. **ユーザー数** — 当面 Kazuki さん単独か、将来マルチユーザー想定か
5. **`garmin_export_samples.py` の実行** — 調査 Phase 0 として可能か（出力 JSON は Issue に貼るか DM、リポジトリには載せない）

---

## 11. 参考リンク

- フォーク: https://github.com/kzkski/python-garminconnect
- Upstream README（認証・API 一覧）: https://github.com/cyberjunky/python-garminconnect
- Garmin Connect Developer Program（公式・enterprise）: https://developer.garmin.com/gc-developer-program/
- MyVitalRelay 実装計画: `docs/implementation-plan.md`
