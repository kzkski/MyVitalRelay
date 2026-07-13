# Claude 向け Garmin データアクセスガイド

MyVitalRelay が管理する Garmin 詳細データの読み方・同期依頼の出し方。

**このドキュメントを読んでから DB にアクセスすること。**

関連: `docs/garmin-sync-ops.md`, `docs/garmin-api-sync-investigation.md`

---

## 0. 最初に守ること（必読）

### Phase 1 で使えるもの / 使えないもの

| 利用可 | Phase 1 未対応（空でも正常） |
|---|---|
| ワークアウト詳細（FIT + API） | 日次 Garmin（HRV / Body Battery / Training Readiness 等） |
| View: `garmin_activity_claude_summary` | View: `garmin_daily_claude` |
| View: `garmin_activity_claude` | `garmin_sync_request` の `scope=daily` / `all` |
| `garmin_sync_request` の `scope=activities` | 全履歴の自動バックフィル |

**`garmin_daily_archive` や `garmin_daily_claude` が 0 件なのは失敗ではない。** Phase 1 では日次 sync ジョブが未実装。

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
| 日次・回復 | **Phase 1 では使わない** | `garmin_daily_claude` |

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
                    │                    Garmin Sync Job (GitHub Actions)
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

## 4. ワークアウト詳細分析の手順（Phase 1）

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
- `scope` は Phase 1 では **`activities` のみ**（`daily` / `all` はジョブが拒否する）
- `user_id` は RLS / default で自動付与

進捗確認:

```http
GET /rest/v1/garmin_sync_request?id=eq.{request_id}&select=id,status,error_message,completed_at
```

**待機:** Sync Job は GitHub Actions「Garmin Sync」で実行される。Phase 1 では cron 自動実行は信頼性が低く、**ユーザーに workflow 手動実行を依頼してもよい**。Webhook 設定後（Phase 1.5）は数十秒〜数分。

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

## 5. 日次データ（Training Readiness / HRV 等）— Phase 1 未対応

**Phase 1 では日次 Garmin 分析を行わない。**

以下は Phase 1.5 で sync ジョブ実装予定:

- `garmin_daily_archive` / View `garmin_daily_claude`
- `scope=daily` の `garmin_sync_request`
- HRV, Body Battery, Training Readiness, Sleep 等

ユーザーが回復状態を聞いてきた場合:

- `training_log` の直近セッション、`sleep_segment`（MyVitalRelay リレー）等 **既存テーブル** で答えられる範囲で回答
- Garmin 日次データが必要なら「Phase 1.5 で対応予定」と伝える
- **`garmin_daily_claude` が空なのを sync 失敗と解釈しない**

---

## 6. 自動同期の範囲（バックフィル）

HealthKit 経由の自動投入は **直近約 14 日** の Garmin ワークアウト upsert 分が対象。全履歴の自動取得はしない。

| 経路 | 取得範囲 |
|---|---|
| iPhone 同期（healthkit） | upsert された Garmin ワークアウトの日付 min〜max |
| Claude 手動依頼 | 指定した `date_from`〜`date_to` |
| 全履歴一括 | Phase 2（目安 90 日バックフィル） |

---

## 7. よくある誤解

| 誤解 | 正しい理解 |
|---|---|
| `complete` = データ取得成功 | ジョブ終了のみ。summary を必ず確認 |
| `garmin_daily_claude` が空 = 失敗 | Phase 1 では常に空で正常 |
| `garmin_activity_archive` を直接見る | View を使う（§0 参照） |
| 認証未設定で complete になる | 認証失敗は通常 `failed`。complete で summary 空なら空振り |
| 10 分待てば必ず cron 実行 | Phase 1 では cron 非信頼。手動 workflow 実行が確実 |

---

## 8. スキーマ参照（簡略）

### `garmin_sync_request` — 同期依頼キュー

| 列 | 説明 |
|---|---|
| `scope` | `activities`（Phase 1 有効）/ `daily` / `all` |
| `date_from`, `date_to` | 取得期間 |
| `status` | `pending` → `running` → `complete` / `failed` |
| `error_message` | `failed` 時の理由 |
| `trigger_source` | `healthkit` / `claude` / `manual` |

### `garmin_activity_claude_summary` — 一覧 View（**最初に見る**）

`training_log` と JOIN 済み。`cadence_spm`, `avg_power_w`, `training_log_id`, `garmin_activity_id` 等。

### `garmin_activity_claude` — 詳細 View（**深掘り時**）

`summary`, `fit_parsed`, `api_responses`（大型 JSONB）を含む。

---

## 9. 今後の Phase（MyVitalRelay）

| Phase | 内容 |
|---|---|
| **1**（現在） | ワークアウト詳細 sync + Claude View。手動 workflow 運用 |
| **1.5** | Webhook 即時トリガー + 日次 sync（`garmin_daily_claude` 有効化） |
| **2** | 過去データ一括バックフィル（目安 90 日） |
| **3** | 本ガイドの整備・エラーハンドリング改善（0 件 complete 検知等） |

ketolog 側の変更は不要。Garmin 連携は MyVitalRelay + Supabase 内で完結する。
