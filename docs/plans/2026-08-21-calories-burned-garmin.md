# 実装計画: training_log.calories_burned を Garmin API 値へ切替

- Issue: [#28](https://github.com/kzkski/MyVitalRelay/issues/28)
- 作成日: 2026-08-21
- 状態: 親レビュー 2 周目反映済み（**実装中**・`feature/garmin-calories-burned-session`）
- 関連（混同しない）: [#27](https://github.com/kzkski/MyVitalRelay/issues/27) は avg_hr / max_hr 削除。本 Issue とは独立

---

## レビュー反映

### 親 1 周目（2026-08-21）

| 指摘 | 反映 |
|---|---|
| PostgREST **バルク** upsert で行ごとにキー集合が違うと危険 | **案 A'** 確定: garmin / 非 garmin で upsert バッチを分割 |
| 「カスタム encode 不要」は誤り | 撤回。キー省略はバッチ内均一が前提。`DailyActivitySummaryRecord` の null 明示方針とも対比して記載 |
| RPC の無駄 UPDATE | `IS DISTINCT FROM` で差分のみ更新（確定） |
| summary 取得フォールバック | 抽出式を `COALESCE(summaryDTO.calories, top-level calories)` に統一 |
| NULL 窓 | AC / 許容仕様に明記。ジョブ失敗時は再キュー |
| Claude 意味論 | アクティブ相当は archive の `calories − bmrCalories` と docs に書く |
| テスト穴 | Python（link 後 apply）・Swift（分割 upsert）をテスト計画に追加 |

### 親 2 周目（2026-08-21）

| 指摘 | 反映 |
|---|---|
| upsert バッチ順序が未確定 | **確定: 先に `includeCalories`（非 garmin）、次に `omitCalories`（garmin）** |
| マイグレーション後に旧アプリ sync でバックフィル巻き戻し | PR/リリース方針・リスクに「アプリ更新優先」「戻ったら apply 再実行」を追記 |

大枠（正 = `summaryDTO.calories` 合計、RPC 書き戻し、非 Garmin は HK、案 A'）は維持。

---

## 背景・ゴール

HealthKit 経由で `training_log.calories_burned` を更新しているが、オーナー観測では Garmin Connect の計測より**著しく低く**見える。

調査の結果、差の主因は「計測精度」ではなく**意味論の違い**である:

| ソース | 値の意味 |
|---|---|
| HealthKit `activeEnergyBurned` | アクティブ消費（セッション中 BMR を含まない） |
| Garmin Connect UI / `summaryDTO.calories` | **合計消費**（セッション中 BMR 込み） |
| Garmin `summaryDTO.bmrCalories` | セッション中の推定 BMR 分 |

本番リンク済みデータでは **HK = Garmin (`calories` − `bmrCalories`)** が一致する（下記「参考」）。オーナーが Connect UI と照合しているなら、正とするべきは合計 `calories` である。

**ゴール:** Garmin 由来ワークアウトの `training_log.calories_burned` を **Garmin `summaryDTO.calories`（合計）** に揃え、HealthKit 再同期で潰されないようにする。非 Garmin 行は現行どおり HealthKit を維持する。

---

## スコープ

### 含む

1. 正フィールドの確定と意味論のドキュメント化（`summaryDTO.calories` = 合計 kcal、DTO 優先 + トップレベルフォールバック）
2. Garmin sync 成功後に `training_log.calories_burned` へ書き戻す経路（RPC + ジョブ呼び出し）
3. iOS 側: `data_source = 'garmin'` の upsert から `calories_burned` を省略し、**バルク時はバッチ分割（案 A'）** で HK 再同期の上書きを防ぐ
4. 過去リンク済み行のバックフィル
5. テスト・ドキュメント追随

### 含まない

- **`daily_activity_summary`**（`active_calories_kcal` / `basal_calories_kcal`）の切替 — 日次は別 Issue 候補。本 Issue はセッション単位の `training_log` のみ
- Issue #27 の avg/max 削除作業そのもの
- FIT からの独自カロリー再計算
- `activeCalories` キーの利用（archive に存在しない）
- `calories − bmrCalories`（アクティブ相当）を正とすること — Connect UI との差分問題を解消しないため不採用（消費者向けの**読み取り**手順としては docs に残す）
- Claude VIEW の必須スキーマ変更（現状 VIEW は `calories_burned` を露出していない）
- Garmin archive の raw JSON 構造変更
- DB トリガーによる上書き保護（案 A' で足りるため不採用）

---

## 調査タスクの結論（Issue チェックリスト）

Issue #28 本文の「調査タスク」に対する計画時点の結論。実装前のブロッカーはなし。

| 調査項目 | 結論 |
|---|---|
| Garmin archive 上のカロリーフィールド | `summary.summaryDTO` 配下に `calories`（値あり）・`bmrCalories`（値あり）・`caloriesConsumed`（稀に 0）。トップレベル `summary.calories` は現状常に NULL。**`activeCalories` キーは無い** |
| 正とするフィールド | **DTO 優先:** `COALESCE(summary->'summaryDTO'->>'calories', summary->>'calories')`（合計 kcal）。Connect UI と同系 |
| HK vs Garmin の定量差 | リンク済み直近 30 件: **30/30 で HK = calories − bmrCalories**。合計との差の平均 ≈ BMR（約 74 kcal）。「HK が著しく低い」感は合計との比較で説明可能 |
| 非 Garmin の扱い | **`life_fitness` / `manual` は HealthKit `activeEnergyBurned` のまま**。NULL 化しない |
| 書き込みタイミング・冪等・HK 上書き防止 | sync ジョブで link 後に RPC で UPDATE（差分のみ・冪等）。iOS は garmin 行でキー省略 + **upsert バッチ分割（A'）** |
| VIEW / Claude / docs | VIEW は現状 `calories_burned` 非露出 → **スキーマ変更不要**。意味論分岐とアクティブ相当の求め方を docs に明記 |
| バックフィル | **要**。リンク済み 77 件すべてに `summaryDTO.calories` あり。一括 SQL で置換可能（抽出式は COALESCE に揃える） |

---

## 設計決定（確定）

### 1. 正とする Garmin フィールドと意味論

| 項目 | 決定 |
|---|---|
| 抽出式（正） | `COALESCE(a.summary->'summaryDTO'->>'calories', a.summary->>'calories')` |
| 優先 | **`summaryDTO.calories` を正**。トップレベルは `garmin_sync_job` が `get_activity or list_summary` で summary を埋める場合のフォールバック |
| 意味 | **合計消費 kcal**（セッション中 BMR 込み）。Garmin Connect アクティビティ詳細のカロリー表示と同系 |
| 採用しない（正としては） | `calories − bmrCalories`、`bmrCalories` 単体、`caloriesConsumed` のみ |
| 列の意味変化 | Garmin 行の `calories_burned` は「アクティブ」から「合計」へ。列名は変更しない。ドキュメントで明示 |

RPC・バックフィル・突合 SQL は**同一抽出式**を使うこと。

### 2. 書き込み経路とタイミング

**推奨: 新規 RPC `apply_garmin_calories_to_training_log(p_user_id uuid) RETURNS integer` + Python ジョブから呼び出し。**

```
iOS SyncEngine
  → training_log upsert を 2 バッチに分割（案 A'）
       · garmin バッチ: calories_burned キー無し
       · 非 garmin バッチ: calories_burned キーあり
  → garmin_sync_request enqueue（garmin 行がある場合）
       │
       ▼
garmin_sync_job
  → archive upsert（summary = get_activity or list 側）
  → link_garmin_activity_training_log(user_id)
  → apply_garmin_calories_to_training_log(user_id)   ← 新規
```

RPC 仕様（草案）:

- `SECURITY DEFINER` / `service_role` のみ（`link_*` と同方針）
- リンク済み行を対象に `calories_burned` を抽出式の値へ UPDATE
- 条件: `t.data_source = 'garmin'` かつ抽出式が非 NULL  
  **かつ** `t.calories_burned IS DISTINCT FROM <抽出値>::numeric`（**確定** — 無用な `updated_at` バンプを避ける）
- 戻り値: 実際に更新した行数
- **冪等**: 値が同じなら 0 行更新
- `link_*` に混ぜない（リンク条件とメトリクス適用を分離。再実行・バックフィルが容易）

タイミング:

1. 通常: activities 同期で link の直後（`scripts/garmin_sync_job.py`）
2. 初回バックフィル: マイグレーション内の一括 UPDATE（同一抽出式 + `IS DISTINCT FROM`）

`link_*` は `training_log_id IS NULL` の行だけを結ぶため、**既リンク行のカロリー更新には別関数が必須**。

### 3. HK 再同期で上書きされない制御（トレードオフと比較）

#### 前提: 単独レコードのキー省略 vs バルク upsert

- 合成 `Codable` は Optional を `encodeIfPresent` するため、`caloriesBurned == nil` なら**そのオブジェクト単体では**キー省略され、PostgREST は列を触らない。
- しかし `SyncEngine` は `upsert(records, ...)` で**配列を一括送信**する。garmin（キー無し）と life_fitness/manual（キー有り）が混在すると、行ごとに列集合が異なりうる。
- 同リポの `DailyActivitySummaryRecord` は意図的にカスタム `encode` で **nil を JSON null として出力**している（コメント: 「PostgREST バルク upsert の列整合 + 明示上書き」）。  
  → **「カスタム encode 不要・nil でキー省略すれば十分」は誤り**（初版計画を撤回）。バルクではキー集合の均一化が必須。

#### 比較表

| 案 | 内容 | 利点 | 欠点 |
|---|---|---|---|
| **A'. バッチ分割（推奨・確定）** | upsert を「calories キーを送るバッチ」（非 garmin）と「送らないバッチ」（garmin）に分割。各バッチ内はキー集合を均一にする。Mapper は garmin で `caloriesBurned = nil`（キー省略） | PostgREST の「無い列は触らない」を安全に使える。null で潰さない。既存の手動注釈列パターンと整合。DB トリガー不要 | SyncEngine に分割ロジックが増える。新規 garmin 行は sync 完了まで NULL（許容仕様） |
| A（分割なし・キー省略のみ） | Mapper だけ nil | 実装が最小 | **バルク混在で列集合不一致 → 却下** |
| 常にキーを送り garmin は null | 列整合は取れる | バッチ分割不要 | **Garmin 合計値を NULL で潰す → 却下**（`DailyActivitySummaryRecord` の「明示上書き」意図と逆。ここは上書き禁止が目的） |
| B. metadata フラグ | `calories_source: garmin` 等 | 監査しやすい | フラグ alone では上書き防止にならない |
| C. DB トリガー保護 | linked garmin 行の calories を HK upsert から守る | 旧アプリ・バルク事故にも耐性 | 挙動が暗黙的。デバッグコスト。方針としては A' の方が明示的で合う → **本 Issue では不採用**（逃げ道としては有効だが過剰） |
| D. A'+C | 二重防御 | 最強 | 単一オーナー運用では過剰 |

**推奨（確定）: 案 A'。**

実装方針:

1. `WorkoutMapper`: `dataSource == "garmin"` なら `caloriesBurned = nil`（エンコード時キー省略）。非 garmin は HK 値。
2. `SyncEngine.syncWorkouts`: records を  
   `garmin` / `非 garmin` に分け、**空でないバッチごとに別 `upsert` を呼ぶ**。  
   **バッチ順序（確定）:** 先に `includeCalories`（非 garmin）、次に `omitCalories`（garmin）。正しさはどちら先でも同じだが、レビュー・ログで非 garmin が先に見えると追いやすい。
3. 分割ロジックは純粋関数（例: `partitionTrainingLogRecordsForCaloriesUpsert(_:) -> (omitCalories:, includeCalories:)`）に切り出し、ユニットテストする。
4. `TrainingLogRecord` に「常に null を送る」カスタム encode は**入れない**（潰すため）。キー省略 + バッチ均一が正解。

デプロイ順:

1. アプリ更新（A': 送らない + バッチ分割）— **マイグレーション適用後は特にアプリ更新を優先**（下記リリース方針）
2. マイグレーション（RPC + バックフィル）
3. ジョブコード（link 後 apply）— 2 と同時可。1 よりジョブだけ先行は避ける

### 4. 非 Garmin（life_fitness / manual）

| `data_source` | `calories_burned` |
|---|---|
| `garmin` | Garmin 抽出式の合計。HK は書かない（キー省略） |
| `life_fitness` | 現行どおり HK `activeEnergyBurned` |
| `manual` | 現行どおり HK `activeEnergyBurned`（あれば） |

Life Fitness / manual を NULL にしない。Garmin 専用の意味論変更に閉じる。

### 5. 過去データのバックフィル

1. マイグレーション内の一括 UPDATE（抽出式 + `IS DISTINCT FROM`）
2. 本番現状: リンク 77 / 未リンク 0、リンク済みすべてに `summaryDTO.calories` あり → COALESCE のフォールバック枝は現状ほぼ未使用だが、RPC / 突合と式を揃える
3. 検証 SQL は Appendix / 検証手順の式に従う

### 6. VIEW / Claude ドキュメント影響

| 対象 | 影響 |
|---|---|
| `garmin_activity_claude_summary` / `garmin_activity_claude` | **変更不要**（`calories_burned` 非露出） |
| `garmin_daily_*` | 対象外 |
| `docs/claude-garmin-access.md` | **必須更新内容:** （1）`training_log.calories_burned` は `data_source` で意味が分岐する — `garmin` = 合計 kcal、`life_fitness` / `manual` = HK アクティブ。（2）**アクティブ相当が欲しければ** archive の `(summaryDTO.calories − summaryDTO.bmrCalories)`（または同等の COALESCE 抽出）を使う |
| `docs/implementation-plan.md` | 列マッピング表を同上の分岐に更新 |
| 任意（本 Issue 必須ではない） | VIEW に `calories_garmin` 露出は将来 Issue 候補 |

### 7. 受け入れ条件・テスト・実装順序

後述セクション参照。

### 8. 含まないもの

上記「スコープ / 含まない」に同じ。特に日次カロリーと #27 を混ぜない。

---

## 現状の影響範囲

調査日: 2026-08-21（リポジトリ + 本番 DB）

### データ経路

| 経路 | calories の扱い（現状 → 変更後） |
|---|---|
| iOS `SyncEngine` → HealthKit | 常に一括 upsert で calories 送信 → **Mapper で garmin は nil + upsert を 2 バッチに分割** |
| Garmin sync scripts | archive のみ。`training_log` 非更新 → **link 後に RPC で UPDATE** |

### DB

| 対象 | 内容 |
|---|---|
| `training_log.calories_burned` | `numeric`。列は残す。意味論のみ garmin 行で変更 |
| `link_garmin_activity_training_log` | リンク専用。変更しない |
| 新規 RPC | `apply_garmin_calories_to_training_log(uuid)`（差分 UPDATE） |
| VIEW | 変更なし |

### アプリ（Swift）

| ファイル | 変更の種類 |
|---|---|
| `MyVitalRelay/Mapping/WorkoutMapper.swift` | garmin 時 `caloriesBurned: nil`。それ以外は `snapshot.activeEnergyKcal` |
| `MyVitalRelay/Sync/SyncEngine.swift` | records を garmin / 非 garmin に分割して別 upsert |
| （新規 or SyncEngine 内）分割ヘルパー | 純粋関数化しテスト可能にする |
| `MyVitalRelay/HealthKit/WorkoutSnapshot.swift` | **変更なし**（HK 読み取りは残す） |
| `MyVitalRelay/Sync/TrainingLogRecord.swift` | **カスタム encode で null 明示はしない**（潰すため）。合成 Codable のキー省略 + バッチ分割で対応 |

### Python / 運用

| ファイル | 変更 |
|---|---|
| `scripts/garmin_sync_job.py` | `link_*` の直後に `apply_garmin_calories_to_training_log` |
| `docs/garmin-sync-ops.md` | ジョブフローに apply ステップ・失敗時再キューの一言 |

### テスト

| ファイル | 変更 |
|---|---|
| `MyVitalRelayTests/WorkoutMapperTests.swift` | garmin で encode に `calories_burned` キー無し / 非 garmin は有り |
| `MyVitalRelayTests`（SyncEngine 分割） | 分割ヘルパーのユニットテスト（混在配列 → 2 グループ、キー集合の期待を固定） |
| `MyVitalRelayTests/GarminSyncRequestRecordTests.swift` | fixture コンパイル追随のみ（必要なら） |
| `tests/test_garmin_sync_lib.py` またはジョブ向けテスト | link 後に apply を呼ぶことを固定（下記テスト計画） |

### ドキュメント

| ファイル | 変更 |
|---|---|
| `docs/implementation-plan.md` | 意味論分岐を記載 |
| `docs/claude-garmin-access.md` | 分岐 + アクティブ相当の求め方 |
| `docs/garmin-sync-ops.md` | link → apply、失敗時再キュー |
| `README.md` | 検証にカロリー突合を 1 行（任意） |

### マイグレーション命名

`supabase/migrations/YYYYMMDDHHMMSS_apply_garmin_calories_to_training_log.sql`

内容: RPC 定義 + GRANT + 既存リンク行のバックフィル UPDATE。

---

## 許容仕様: NULL 窓

案 A' 採用時、**新規 garmin 行は Garmin sync（link + apply）完了まで `calories_burned` が NULL** になりうる。

| 状況 | 扱い |
|---|---|
| HK 同期直後〜ジョブ完了前 | NULL。**許容仕様**（AC で明示） |
| ジョブ成功後 | 抽出式の合計値 |
| ジョブ失敗 / partial | NULL または古い HK 値が残る可能性。運用: `garmin_sync_request` の再キュー / 手動 Run / Backfill workflow（既存運用）。apply は冪等なので再実行で埋まる |

「常に即座に数値が入る」ことは本 Issue の AC に含めない。

---

## PR / リリース方針

**単一 PR**（アプリ + マイグレーション + Python ジョブ + docs）を推奨。

デプロイ順（必須）:

1. **アプリ更新**（A': キー省略 + バッチ分割）
2. **マイグレーション適用**（RPC + バックフィル）
3. **ジョブコードデプロイ** — 2 と同時でも可

**旧アプリによる巻き戻し窓:** マイグレーション（バックフィル）後に **未更新アプリ** が sync すると、旧挙動（garmin でも `calories_burned` 送信・分割なし）で HK アクティブ値に戻る。  
→ **マイグレーション適用後はアプリ更新を最優先**する。万一戻ったら `apply_garmin_calories_to_training_log`（ジョブ再実行 / RPC 手動）で復帰可能。  
マイグレーション先行のみ（アプリ未更新）や、バックフィル直後に旧アプリを動かし続けることは避ける。

---

## 実装ステップ（順序）

### Step 1: アプリ — Mapper + 分割 upsert（案 A'）

1. `WorkoutMapper.record`:

```swift
let source = dataSource(sourceName: snapshot.sourceName, bundleId: snapshot.sourceBundleId)
// ...
caloriesBurned: source == "garmin" ? nil : snapshot.activeEnergyKcal,
```

2. 分割ヘルパー（例）を追加し、`SyncEngine` から呼ぶ:

```swift
// 純粋関数: garmin（calories キー省略）とそれ以外に分割
func partitionTrainingLogRecordsForCaloriesUpsert(
    _ records: [TrainingLogRecord]
) -> (omitCalories: [TrainingLogRecord], includeCalories: [TrainingLogRecord])
```

3. 各パーティションが空でなければ、それぞれ `upsert(..., onConflict: "user_id,start_time,end_time,workout_type")` を実行。  
   **順序（確定）:** `includeCalories` → `omitCalories`。

4. `GarminSyncRequestEnqueuer` は従来どおり garmin records から enqueue（分割後も garmin 配列を渡せばよい）。

`WorkoutSnapshot` の HK 読み取りは残す。

### Step 2: Swift ユニットテスト

- garmin → encode に `"calories_burned"` 無し
- 非 garmin → キーあり
- **分割ヘルパー:** 混在配列 → omit / include の件数と `dataSource` 分布が正しいこと。各グループを encode した JSON 配列で、omit 側に `calories_burned` が一切現れないこと
- 既存の手動注釈列除外テストは維持

### Step 3: DB マイグレーション — RPC + バックフィル

Appendix A をベースに:

1. `apply_garmin_calories_to_training_log(uuid)` を CREATE（COALESCE 抽出 + `IS DISTINCT FROM`）
2. `REVOKE` / `GRANT EXECUTE ... TO service_role`
3. バックフィル一括 UPDATE（同一式）

`link_garmin_activity_training_log` は変更しない。

### Step 4: Python ジョブ

`process_request` 内（activities スコープ時）:

```python
sb.rpc("link_garmin_activity_training_log", {"p_user_id": user_id}).execute()
sb.rpc("apply_garmin_calories_to_training_log", {"p_user_id": user_id}).execute()
```

### Step 5: ドキュメント

- `implementation-plan` / `claude-garmin-access` / `garmin-sync-ops`
- Claude 向け: 意味論分岐 + アクティブ相当 = `calories − bmrCalories`
- NULL 窓とジョブ再キューを ops に一言

### Step 6: 適用・検証

受け入れ条件・検証手順に沿う。

---

## テスト計画

| 種別 | 内容 |
|---|---|
| ユニット (Swift) | garmin ソースで `calories_burned` キー省略 |
| ユニット (Swift) | life_fitness / manual 相当で HK カロリーがエンコードされる |
| ユニット (Swift) | **分割ヘルパー** — 混在配列のパーティションと、omit バッチ encode に calories キーが無いこと（推奨・純粋関数なら必須に近い） |
| ユニット (Python) | **link の後に apply を呼ぶこと**を固定。手段: (a) `process_request` をモック client で呼び RPC 名の呼び出し順を assert、または (b) 呼び出し順を薄いヘルパー（例: `link_then_apply_calories(sb, user_id)`）に切り出して単体テスト。既存 `tests/test_garmin_sync_lib.py` へ追記で可。実装時にどちらかを選ぶ |
| DB | RPC 実行後、突合 SQL で mismatch = 0 |
| DB | 値が同じ行で再実行すると更新 0・`updated_at` 不変（差分条件の確認） |
| DB | 非 garmin 行の `calories_burned` が RPC で変わらないこと |
| 実機 | Garmin 再同期 → 合計維持。新規 garmin はジョブ完了まで NULL → 完了後に合計 |
| 実機 / SQL | Life Fitness 行は従来どおり HK 値 |

---

## リスクと注意点

1. **意味論の破壊的変更（garmin 行のみ）**  
   過去の分析が「アクティブ kcal」前提なら数値が跳ねる。Claude docs で分岐とアクティブ相当の求め方を明示する。

2. **PostgREST バルク upsert の列集合**  
   キー省略は**バッチ内均一**が前提。混在一括は禁止（案 A'）。常に null 送信は Garmin 値を潰すため禁止。

3. **デプロイ順序 / 旧アプリ巻き戻し**  
   アプリ更新を優先。バックフィル後に未更新アプリが sync すると HK アクティブへ戻る → ジョブ再実行 / apply RPC で復帰。

4. **NULL 窓（許容）**  
   新規 garmin は apply まで NULL。ジョブ失敗時は再キュー。

5. **#27 との並行**  
   `WorkoutMapper` / tests / SyncEngine が重なりうる。コンフリクトに注意。責務は混ぜない。

6. **日次テーブルとの混同**  
   `daily_activity_summary` は触らない。

---

## 受け入れ条件（Issue AC 対応）

- [ ] Garmin 由来ワークアウトの `calories_burned` が抽出式（DTO 優先 COALESCE）の合計と一致する（ジョブ完了後）
- [ ] HealthKit 再同期後も Garmin 合計値が維持される（garmin バッチに calories キー無し + バッチ分割）
- [ ] **許容:** 新規 garmin 行は Garmin sync（link + apply）完了まで `calories_burned` が NULL でよい。完了後に合計が入る
- [ ] ジョブ失敗後も再キュー / 再実行で apply が埋まる（運用で確認可能なこと）
- [ ] `life_fitness` / `manual` は HK `activeEnergyBurned` のまま
- [ ] 過去リンク済み行がバックフィル済み（mismatch = 0）
- [ ] 関連テスト・ドキュメントが更新されている（Claude の意味論分岐・アクティブ相当の求め方を含む）

---

## 検証手順

1. **ユニットテスト**  
   Swift（Mapper + 分割）および Python（link→apply 順）がグリーン。

2. **突合 SQL**

```sql
SELECT
  t.date,
  t.calories_burned AS training_log_cal,
  COALESCE(
    a.summary->'summaryDTO'->>'calories',
    a.summary->>'calories'
  )::numeric AS garmin_total,
  (a.summary->'summaryDTO'->>'bmrCalories')::numeric AS garmin_bmr
FROM garmin_activity_archive a
JOIN training_log t ON t.id = a.training_log_id
ORDER BY a.start_time_local DESC
LIMIT 10;
-- training_log_cal = garmin_total であること（ジョブ完了後の行）
```

mismatch 集計:

```sql
SELECT count(*) AS mismatch
FROM garmin_activity_archive a
JOIN training_log t ON t.id = a.training_log_id
WHERE t.data_source = 'garmin'
  AND COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      ) IS NOT NULL
  AND t.calories_burned IS DISTINCT FROM COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      )::numeric;
-- 期待: 0（バックフィル・ジョブ完了後）
```

3. **実機再同期**  
   既存 Garmin → 合計維持。新規 Garmin → 同期直後は NULL 可、ジョブ後に合計。

4. **回帰**  
   Life Fitness 由来行が消えない・RPC の影響を受けない。

---

## 参考（調査で確認した事実）

### フィールド存在（本番 archive）

- `summaryDTO.calories` / `bmrCalories`: 値あり
- `summaryDTO.caloriesConsumed`: たまに 0
- トップレベル `summary.calories`: null（フォールバック枝用に式には残す）
- `activeCalories`: キー無し

### HK vs Garmin（リンク済み例）

| date | HK calories_burned | summaryDTO.calories | bmrCalories | calories − bmr |
|---|---|---|---|---|
| 2026-08-20 | 752 | 847 | 95 | 752 |
| 2026-08-18 | 573 | 658 | 85 | 573 |
| 2026-08-16 | 735 | 834 | 99 | 735 |

直近リンク 30 件: HK と (calories − bmr) の一致 30/30。合計との一致 0/30。

リンク済み全体: 77 件、すべて `summaryDTO.calories` あり。未リンク 0。

### アーキテクチャ制約（再確認）

- iOS: HealthKit → `training_log` **配列** upsert。現状 Mapper が常に calories を送る
- `DailyActivitySummaryRecord` はバルク列整合のため nil→JSON null（本 Issue では「潰したくない」ので逆の戦略 = キー省略 + バッチ分割）
- Garmin sync: archive + `link_*`。calories は未書き込み。`summary = get_activity or list`
- PostgREST upsert はペイロードにある列だけ更新（**バッチ内の列集合が前提**）
- `data_source` ∈ {garmin, life_fitness, manual}

---

## Appendix A: RPC / バックフィル SQL 草案

ファイル名例: `supabase/migrations/20260821120000_apply_garmin_calories_to_training_log.sql`

```sql
-- Garmin archive の calories（合計）を training_log.calories_burned に反映する。
-- Issue #28
-- 抽出: COALESCE(summaryDTO.calories, top-level calories)
-- 意味論: Garmin 行はセッション合計 kcal（BMR 込み）。life_fitness / manual は触らない。

CREATE OR REPLACE FUNCTION apply_garmin_calories_to_training_log(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected integer;
BEGIN
  UPDATE training_log t
  SET
    calories_burned = COALESCE(
      a.summary->'summaryDTO'->>'calories',
      a.summary->>'calories'
    )::numeric,
    updated_at = now()
  FROM garmin_activity_archive a
  WHERE a.training_log_id = t.id
    AND a.user_id = p_user_id
    AND t.user_id = p_user_id
    AND t.data_source = 'garmin'
    AND COALESCE(
          a.summary->'summaryDTO'->>'calories',
          a.summary->>'calories'
        ) IS NOT NULL
    AND t.calories_burned IS DISTINCT FROM COALESCE(
          a.summary->'summaryDTO'->>'calories',
          a.summary->>'calories'
        )::numeric;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

REVOKE ALL ON FUNCTION apply_garmin_calories_to_training_log(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION apply_garmin_calories_to_training_log(uuid) TO service_role;

-- バックフィル（全リンク済み garmin 行・差分のみ）
UPDATE training_log t
SET
  calories_burned = COALESCE(
    a.summary->'summaryDTO'->>'calories',
    a.summary->>'calories'
  )::numeric,
  updated_at = now()
FROM garmin_activity_archive a
WHERE a.training_log_id = t.id
  AND t.data_source = 'garmin'
  AND COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      ) IS NOT NULL
  AND t.calories_burned IS DISTINCT FROM COALESCE(
        a.summary->'summaryDTO'->>'calories',
        a.summary->>'calories'
      )::numeric;
```

---

## Appendix B: 実装時の確認チェックリスト（開発者向け）

- [ ] `WorkoutMapper` で garmin のみ nil（life_fitness を誤って潰していない）
- [ ] **SyncEngine が garmin / 非 garmin で upsert を分割**している（混在一括禁止）。順序は includeCalories → omitCalories
- [ ] garmin に JSON null の `calories_burned` を送っていない（潰すため禁止）
- [ ] encode / 分割ヘルパーのテストでキー省略を固定
- [ ] ジョブが link の**後**に apply を呼ぶ（Python テストまたはヘルパーテスト）
- [ ] RPC が COALESCE 抽出 + `IS DISTINCT FROM`、かつ非 garmin を更新しない
- [ ] docs に合計 vs アクティブ分岐、およびアクティブ相当 = `calories − bmrCalories` を書いた
- [ ] NULL 窓が AC / ops に書いてある
- [ ] #27 の変更とコンフリクトしていない
