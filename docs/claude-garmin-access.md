# Claude 向け Garmin データアクセスガイド

MyVitalRelay が管理する Garmin 詳細データの読み方・同期依頼の出し方。

**このドキュメントを読んでから DB にアクセスすること。**

関連: `docs/garmin-sync-ops.md`, `docs/garmin-api-sync-investigation.md`

---

## 0. 最初に守ること（必読）

### 現在使えるもの

| 機能 | 備考 |
|---|---|
| ワークアウト詳細（FIT + API） | `scope=activities` |
| View: `garmin_activity_claude_summary` / `garmin_activity_claude` | 分析は View 経由 |
| 日次 Garmin | `scope=daily` / `garmin_daily_claude` |
| 90 日バックフィル | Garmin Backfill workflow |
| 即時トリガー | HealthKit / Claude INSERT → pg_net → GitHub Actions（**実装済み**） |

### 同期完了の判定 — `status=complete` だけでは足りない

`garmin_sync_request.status = complete` は **「ジョブが例外なく終了した」** 意味であり、**データが取れた保証ではない**。

| status | 意味 |
|---|---|
| `pending` | キュー待ち。Sync Job 未実行 |
| `running` | 処理中 |
| `complete` | ジョブ終了。**0 件でも complete になりうる** |
| `failed` | 例外発生。`error_message` を確認 |
| `partial` | 一部 activity で FIT 等が失敗（archive 側の `sync_status`） |

**分析前に必ず確認:**

1. `garmin_activity_claude_summary` に対象期間の行があるか
2. 無ければ同期依頼 → ジョブ実行待ち → **再度 summary を確認**
3. summary が 0 件のままなら「期間内に Garmin activity なし」または「同期空振り」と報告する

**`garmin_sync_request` が complete なのに summary が空、という組み合わせは起こりうる。** 認証失敗と決め打ちしない。

### 読む View の優先順位

| 用途 | 使うもの | 使わないもの |
|---|---|---|
| 一覧・会話開始 | `garmin_activity_claude_summary` | `garmin_activity_archive`（内部テーブル） |
| 1 件の深掘り | `garmin_activity_claude` | 生テーブルへの直接 SELECT |
| 日次・回復 | `garmin_daily_claude` | `garmin_daily_archive`（内部テーブル） |

FIT バイナリ（Storage）は Claude から読めない。`fit_parsed` / `api_responses` の JSON を使う。

---

## 1. 前提（MyVitalRelay と Supabase）

- Garmin 詳細同期は **MyVitalRelay** の機能。ketolog 等の他アプリとは **論理分離**（同じ Supabase プロジェクトを同居利用しているだけ）。
- Claude は **Supabase PostgREST + RLS** でアクセスする（refresh_token → access_token → Bearer）。
- RLS により **ログインユーザー本人の `user_id` の行のみ** 読める。
- ワークアウト概要の正: `training_log`（MyVitalRelay / HealthKit リレー）
- Garmin 詳細（FIT 解析・API 全量）の正: `garmin_activity_archive` → View 経由で読む

---

## 2. 全体フロー

```
Garmin Watch → Garmin Connect → HealthKit
                                    │
                                    ▼
                          MyVitalRelay（iOS 同期）
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            training_log upsert          garmin_sync_request INSERT
            (概要: 距離・HR・RPE 等)         (trigger_source=healthkit)
                                                    │
Claude（会話中）──INSERT garmin_sync_request────────┤
(trigger_source=claude)                             │
                    │                               ▼
                    │              pg_net → Edge Function → GitHub Actions
                    │                               │
                    │                    Garmin Sync Job (garmin_sync_job.py)
                    │                               │
                    └────────SELECT─────────────────┤
                              garmin_activity_claude_* (View)
```

| trigger_source | 誰が INSERT するか |
|---|---|
| `healthkit` | MyVitalRelay — Garmin ワークアウト upsert 後 |
| `claude` | Claude — 分析前に不足データを補完 |
| `manual` | 運用者 / workflow 手動実行 |

---

## 3. PostgREST アクセス例

認証済み Bearer トークンで:

```http
GET /rest/v1/training_log?select=id,date,discipline,distance_km,rpe,condition_notes,data_source&date=eq.2026-07-10&data_source=eq.garmin
```

Garmin 詳細（一覧）:

```http
GET /rest/v1/garmin_activity_claude_summary?training_log_date=eq.2026-07-10&select=activity_name,cadence_spm,avg_power_w,training_log_id,garmin_activity_id,synced_at
```

Garmin 詳細（1 件深掘り）:

```http
GET /rest/v1/garmin_activity_claude?training_log_id=eq.{uuid}&select=activity_name,summary,fit_parsed,api_responses,fit_parsed_in_storage,api_responses_in_storage
```

PostgREST では `api_responses->get_activity_splits` のような JSON path フィルタは使えない。深掘り時は `api_responses` 列全体を select し、JSON 内を解析する。

大型 JSON（512KB 超）は Storage 退避。View の `fit_parsed_in_storage` / `api_responses_in_storage` が `true` ならインライン JSON は空 `{}` で正常。

---

## 4. ワークアウト詳細分析の手順

### Step 1: 対象セッションを特定

```http
GET /rest/v1/training_log?select=id,date,discipline,start_time,rpe,condition_notes&date=gte.2026-07-07&date=lte.2026-07-12&data_source=eq.garmin&order=start_time.desc
```

主観データ（RPE, condition_notes）は `training_log` にある。Garmin 詳細と **統合して** 回答する。

### Step 2: Garmin 詳細があるか確認（summary View）

```http
GET /rest/v1/garmin_activity_claude_summary?training_log_id=eq.{training_log_id}&select=*
```

または日付で:

```http
GET /rest/v1/garmin_activity_claude_summary?training_log_date=eq.2026-07-10&select=*
```

**行があれば Step 4 へ。** 無ければ Step 3。

### Step 3: 同期依頼（必要な場合のみ）

```http
POST /rest/v1/garmin_sync_request
Content-Type: application/json
Prefer: return=representation

{
  "scope": "activities",
  "date_from": "2026-07-09",
  "date_to": "2026-07-11",
  "trigger_source": "claude"
}
```

- `date_from` / `date_to` は分析対象日 **±1 日** 程度
- ワークアウト詳細のみ必要なら `scope=activities`。日次指標も必要なら `daily` / `all` も可
- `user_id` は RLS / default で自動付与

進捗確認:

```http
GET /rest/v1/garmin_sync_request?id=eq.{request_id}&select=id,status,error_message,completed_at
```

**待機:** INSERT 後、pg_net トリガー経由で GitHub Actions が **数十秒〜2分** で起動する。`status` をポーリングする。Webhook / PAT 障害時のみ、ユーザーに **Garmin Sync 手動 Run** を依頼する。

**`status=complete` になったら Step 2 をやり直す。** summary に行が無ければ「同期空振り」と報告し、`error_message` や期間を確認する。

### Step 4: 深掘り分析

```http
GET /rest/v1/garmin_activity_claude?garmin_activity_id=eq.{id}&select=activity_name,summary,fit_parsed,api_responses
```

分析に使える JSON キー例:

- `api_responses.get_activity_splits` — ラップ分割
- `api_responses.get_activity_hr_in_timezones` — 心拍ゾーン
- `api_responses.get_activity_exercise_sets` — 筋トレセット
- `fit_parsed.messages` — FIT 全メッセージ（ラップ・記録等）

---

## 5. 日次データ（回復・コンディション）

日次 sync は **実装済み**。`garmin_sync_request` に `scope=daily` または `scope=all` で依頼する。

### Training Readiness と機種差（要チェック項目）

**オーナー機種: Forerunner 255** — **Training Readiness 非搭載**（955 等の上位機種専用。FW アップデートでも追加されない）。

そのため `garmin_daily_claude.training_readiness` は **全日程 `[]` が正常**（同期失敗・Connect+ 不足ではない）。

回復・コンディション判断は **代替指標** を使う:

| 指標 | View 列 / JSON キー | 用途 |
|---|---|---|
| HRV ステータス | `hrv`（`get_hrv_data`） | ベースライン比較、オーバー/アンダー傾向 |
| Body Battery | `body_battery` | 当日のエネルギー残量（1〜100） |
| 睡眠スコア | `sleep`（`get_sleep_data`） | 昨夜の睡眠質・回復 |
| トレーニングステータス | `api_responses` → `get_training_status` | VO2 Max、負荷状態等 |
| リカバリータイム | ワークアウト詳細 or 日次 JSON 内 | 前回練習からの回復残時間（機種・記録による） |

```http
POST /rest/v1/garmin_sync_request
Content-Type: application/json

{
  "scope": "daily",
  "date_from": "2026-07-07",
  "date_to": "2026-07-12",
  "trigger_source": "claude"
}
```

取得後（**FR255 では `training_readiness` は見なくてよい**）:

```http
GET /rest/v1/garmin_daily_claude?date=eq.2026-07-12&select=date,hrv,body_battery,sleep,api_responses
```

**まだ sync していない日は 0 件で正常。** 上記 POST → 数十秒待ち → 再 SELECT。

ユーザーが回復状態を聞いてきた場合:

- 先に `garmin_daily_claude` の **hrv / body_battery / sleep** を確認
- `training_readiness` が `[]` でも **異常ではない**（255 では常に空）
- 無ければ `scope=daily` で同期依頼
- `training_log` / `sleep_segment` と統合して回答

---

## 6. 自動同期の範囲（バックフィル）

HealthKit 経由の自動投入は **直近約 14 日** の Garmin ワークアウト upsert 分が対象。全履歴の自動取得はしない。

| 経路 | 取得範囲 |
|---|---|
| iPhone 同期（healthkit） | upsert された Garmin ワークアウトの日付 min〜max |
| Claude 手動依頼 | 指定した `date_from`〜`date_to` |
| **Garmin Backfill workflow** | 過去 90 日（14 日 chunk、手動実行） |

---

## 7. よくある誤解

| 誤解 | 正しい理解 |
|---|---|
| `complete` = データ取得成功 | ジョブ終了のみ。summary を必ず確認 |
| `garmin_daily_claude` が空 = 失敗 | **未 sync の日は空で正常**。`scope=daily` で依頼 |
| `training_readiness` が `[]` | **FR255 では正常**（機種非搭載）。HRV / Body Battery / sleep を使う |
| `garmin_activity_archive` を直接見る | View を使う（§0 参照） |
| 認証未設定で complete になる | 認証失敗は通常 `failed`。complete で summary 空なら空振り |
| INSERT 後すぐ summary に行が出る | Webhook → GitHub Actions 起動に数十秒〜2分。`status` をポーリング |
| Webhook 失敗時 | **Garmin Sync 手動 Run** で pending 全件を処理可能 |

---

## 8. スキーマ参照（簡略）

### `garmin_sync_request` — 同期依頼キュー

| 列 | 説明 |
|---|---|
| `scope` | `activities` / `daily` / `all` |
| `date_from`, `date_to` | 取得期間 |
| `status` | `pending` → `running` → `complete` / `failed` |
| `error_message` | `failed` 時の理由 |
| `trigger_source` | `healthkit` / `claude` / `manual` |

### `garmin_activity_claude_summary` — 一覧 View（**最初に見る**）

`training_log` と JOIN 済み。`cadence_spm`, `avg_power_w`, `training_log_id`, `garmin_activity_id` 等。

### `garmin_activity_claude` — 詳細 View（**深掘り時**）

`summary`, `fit_parsed`, `api_responses`（大型 JSONB）を含む。

---

## 9. Phase 履歴（MyVitalRelay）

| Phase | 内容 | 状態 |
|---|---|---|
| **1** | ワークアウト詳細 sync + Claude View | ✅ |
| **1.5** | 日次 sync + pg_net Webhook 即時トリガー | ✅ |
| **2** | 90 日バックフィル workflow | ✅ |
| **3** | Claude ガイド整備・空振り `partial` 判定 | ✅ |

ketolog 側の変更は不要。Garmin 連携は MyVitalRelay + Supabase 内で完結する。
