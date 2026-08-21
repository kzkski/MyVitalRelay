# 実装計画: training_log から avg_hr / max_hr を削除する

- Issue: [#27](https://github.com/kzkski/MyVitalRelay/issues/27)
- 作成日: 2026-07-31
- 状態: 実装完了（2026-08-21）
- レビュー: 親エージェント 2 周目まで反映済み（2026-07-31）

---

## 背景・ゴール

HealthKit 経由で `training_log.avg_hr` / `max_hr` を取得・永続化しているが、トレーニング管理上の価値が薄い。

- HealthKit の avg/max は Garmin Connect API（`summaryDTO.averageHR` / `maxHR`）と比べ系統的にズレる
- セッション全体平均だけでは強度配分を把握できない。本命は `hr_zone_minutes`

**ゴール:** HealthKit 同期で avg/max を書かないようにし、`training_log` から列ごと DROP する。`hr_zone_minutes` の同期は維持する。Garmin archive 内の avg/max はアーカイブとして残し、VIEW から `summaryDTO` 経由で露出する。

**Breaking change（VIEW）:** `garmin_activity_claude_summary` から training_log 由来の `avg_hr` が消え、代わりに `avg_hr_garmin` / `max_hr_garmin`（Garmin archive）を使う。

---

## スコープ

### 含む

1. アプリ: HealthKit 同期ペイロードから `avg_hr` / `max_hr` を除去し、avg/max 算出をゾーン集計から切り離す
2. DB: `training_log.avg_hr` / `max_hr` を DROP するマイグレーション（過去データ破棄で可）
3. VIEW: `garmin_activity_claude_summary`（および連鎖の `garmin_activity_claude`）を再作成
   - `t.avg_hr` を削除
   - `avg_hr_garmin` のパスを `summary->'summaryDTO'->>'averageHR'` に修正
   - `max_hr_garmin`（`summary->'summaryDTO'->>'maxHR'`）を**新規露出**（AC「Garmin archive 参照に切替」の代替）
4. テスト・ドキュメントの追随

### 含まない

- `hr_zone_minutes` の削除・仕様変更・ゾーン境界ソース改善（`fixed_default` 固定問題は別 Issue）
- Garmin API から avg/max を `training_log` に書き戻すこと
- `HeartRateZoneBoundaries` 内の `maxHr = 220 - age`（ゾーン境界計算用。本 Issue の列とは無関係）
- Garmin archive の raw JSON 構造変更
- **他の summary キー（`distance` / cadence / power / TE / training_load 等）のパス修正** — 今回は HR のみ。トップレベル参照のままでよい
- `garmin_daily_claude` / `garmin_daily_summary` への変更
- Insights / Claude プロンプトの大規模改修（VIEW カラム追随は最小限）

---

## 調査タスクの結論（Issue チェックリスト）

Issue #27 本文の「調査タスク」に対する計画時点の結論。実装前のブロッカーはなし。

| 調査項目 | 結論 |
|---|---|
| Claude / Insights / 手動 SQL / 外部ツールが `training_log.avg_hr` / `max_hr` を参照しているか | **リポジトリ内**では VIEW `garmin_activity_claude_summary` の `t.avg_hr` のみ。Garmin sync scripts / テストに書き込みなし。外部 Claude 会話の過去クエリまでは保証できないが、VIEW 更新（`avg_hr_garmin` / `max_hr_garmin`）で追随可能 |
| VIEW / RLS への影響 | `garmin_activity_claude_summary` + 連鎖の `garmin_activity_claude` のみ。`garmin_daily_*` は無関係。RLS ポリシーの追加変更は不要（VIEW は `security_invoker = true`） |
| upsert から列を外したとき既存値が残るか | PostgREST はペイロード列のみ更新 → **既存値は残る** → 過去データ消去には **列 DROP が必須** |
| ゾーン算出を維持したまま avg/max だけ切れるか | **可能**。サンプル取得 → ゾーンバケット集計はそのまま、avg/max の statistics 優先・加重平均・サンプル max のみ削除 |

---

## 現状の影響範囲

調査日: 2026-07-31（リポジトリ + 本番 DB）

### データ経路

| 経路 | avg/max の扱い |
|---|---|
| iOS `SyncEngine` → HealthKit | `WorkoutSnapshot` が HK statistics で初期値 → `WorkoutHeartRateFetcher.enrich` → `HeartRateZoneCalculator.aggregate` が補完 → `WorkoutMapper` が `avg_hr` / `max_hr` を upsert |
| Garmin sync scripts | `training_log` の avg/max は書いていない。archive の `summary.summaryDTO` に `averageHR` / `maxHR` が残る |

### DB

| 対象 | 内容 |
|---|---|
| `training_log.avg_hr` | `numeric`（作成: `20260704063000_create_training_log.sql`） |
| `training_log.max_hr` | 同上 |
| `training_log.hr_zone_minutes` | **残す**（本 Issue 対象外） |
| 依存 VIEW | `garmin_activity_claude_summary` のみ（`training_log` を参照）。`garmin_activity_claude` は summary VIEW を `s.*` で拡張するため連鎖影響あり |
| 触らない VIEW | `garmin_daily_claude` / `garmin_daily_summary`（本マイグレーションでは DROP / CREATE しない） |
| 他 VIEW / RLS | `avg_hr` / `max_hr` への追加依存なし |

本番確認メモ:

- `garmin_activity_archive.summary->>'averageHR'` は常に NULL（パス誤り）
- 実体は `summary->'summaryDTO'->>'averageHR'` / `'maxHR'`（値あり）

### アプリ（Swift）

| ファイル | 変更の種類 |
|---|---|
| `MyVitalRelay/Sync/TrainingLogRecord.swift` | `avgHr` / `maxHr` プロパティ・CodingKeys 削除 |
| `MyVitalRelay/Mapping/WorkoutMapper.swift` | マッピングから除去 |
| `MyVitalRelay/HealthKit/WorkoutSnapshot.swift` | `avgHeartRate` / `maxHeartRate` 削除、HK statistics 取得削除 |
| `MyVitalRelay/Sync/SyncEngine.swift` | enrich への statistics 引き渡し・snapshot への avg/max 書き戻し削除 |
| `MyVitalRelay/HealthKit/WorkoutHeartRateFetcher.swift` | `enrich` の `statisticsAvg` / `statisticsMax` 引数削除 |
| `MyVitalRelay/Mapping/HeartRateZoneCalculator.swift` | `HeartRateAggregation` から `avgBpm` / `maxBpm` 削除。`aggregate` から statistics 引数と avg/max 集計を除去（ゾーン集計のみ残す） |

変更しない:

- `MyVitalRelay/Mapping/HeartRateZoneBoundaries.swift`（年齢ベース max HR はゾーン境界用）
- Garmin sync / interval.icu 関連スクリプト（`training_log` に avg/max を書いていない）

### テスト

| ファイル | 変更 |
|---|---|
| `MyVitalRelayTests/WorkoutMapperTests.swift` | `avgHr` / `maxHr` アサーション・fixture 引数削除 |
| `MyVitalRelayTests/GarminSyncRequestRecordTests.swift` | `makeRecord` から `avgHr` / `maxHr` 削除 |
| `MyVitalRelayTests/HeartRateZoneCalculatorTests.swift` | `testAggregate_statisticsPriority` / `testAggregate_statisticsNil_fallbackToSamples` / empty 時の avg/max アサーション削除。ゾーン系テストは維持。`aggregate` シグネチャ変更に追随 |

### ドキュメント

| ファイル | 変更 |
|---|---|
| `docs/implementation-plan.md` | 列マッピング表から `avg_hr` / `max_hr` 行を削除（または「削除済み」注記） |
| `README.md` | Garmin 検証文言「心拍・獲得標高あり」をゾーン中心に修正（`hr_zone_minutes` は既存記載あり） |
| `docs/claude-garmin-access.md` | `avg_hr_garmin` / `max_hr_garmin` のパス注記を最小更新 |

### マイグレーション命名（既存スタイル）

`supabase/migrations/YYYYMMDDHHMMSS_<snake_case_description>.sql`

例: `20260731120000_drop_training_log_avg_max_hr.sql`

---

## PR / リリース方針

**単一 PR**（アプリ + マイグレーション + docs）。本番適用は **アプリ更新（TestFlight / 実機）→ マイグレーション適用** の順。マイグレーション先行は禁止（旧アプリが DROP 済み列を upsert ペイロードに含め、PostgREST が未知列で失敗する可能性があるため）。

---

## 実装ステップ（順序）

### Step 1: アプリ側 — 書き込み停止 + ゾーン算出の切り離し

**目的:** マイグレーション前に新規 upsert が `avg_hr` / `max_hr` を送らない状態にする。

**注意:** PostgREST はペイロードにある列のみ更新する。アプリだけ先にデプロイしても**既存行の avg/max は残る**。クリアは Step 3 の DROP に依存する。

変更内容:

1. `HeartRateZoneCalculator.aggregate`
   - 引数 `statisticsAvg` / `statisticsMax` を削除
   - ループ内の `weightedBpmSum` / `totalSeconds`（avg 用）と `maxBpm` 追跡を削除
   - 戻り値は `zoneMinutes` + `zoneSource` のみ
2. `HeartRateAggregation` から `avgBpm` / `maxBpm` を削除
3. `WorkoutHeartRateFetcher.enrich` から statistics 引数を削除
4. `WorkoutSnapshot` から `avgHeartRate` / `maxHeartRate` と HK statistics 読み取りを削除
5. `SyncEngine` の enrich 呼び出し・書き戻しをゾーンのみに簡略化
6. `TrainingLogRecord` / `WorkoutMapper` から avg/max を削除

### Step 2: テスト更新

同一 PR でユニットテストをコンパイル・グリーンにする。

- Mapper / GarminSync fixture から avg/max を除去
- ZoneCalculator: ゾーン系テストは残し、avg/max 専用テストは削除
- `testEncodeExcludesManualAnnotationColumns` は現行どおり（`rpe` 等の手動注釈列除外の固定）。**avg/max 用のエンコード検証は追加不要**（型から列が消えるため自然に含まれない）

### Step 3: DB マイグレーション — VIEW 再作成 + DROP 列

PostgreSQL は VIEW が参照している列を DROP できない。

再現手順:

1. 既存 `20260712120000_garmin_sync_claude_access.sql` の該当 VIEW 定義をベースにコピーする
2. `garmin_activity_claude` / `garmin_activity_claude_summary` のみ DROP（**`garmin_daily_claude` は触らない**）
3. `training_log` から `avg_hr` / `max_hr` を DROP
4. SELECT リストを編集: `t.avg_hr` 削除、`avg_hr_garmin` を `summaryDTO` パスに修正、`max_hr_garmin` 追加。distance / cadence / power 等は**現行パスのまま**
5. `security_invoker = true` と `GRANT SELECT ... TO authenticated` を既存どおり再現

完全 SQL 草案は末尾 **Appendix A** を参照（実装時にファイルへコピペ可）。

### Step 4: ドキュメント更新

- `docs/implementation-plan.md`: 列マッピングから削除
- `README.md`: 検証チェックリストの「心拍」表現を `hr_zone_minutes` 中心に修正
- `docs/claude-garmin-access.md`: `avg_hr_garmin` / `max_hr_garmin`（`summaryDTO`）の注記を追加。training_log 由来 `avg_hr` 削除の Breaking change を1行で記載

### Step 5: 適用・検証

1. アプリビルド + ユニットテスト
2. マイグレーションをローカルで適用して確認 → 本番はアプリ更新後に適用
3. 受け入れ条件・検証手順に沿って確認

---

## マイグレーション方針

| 項目 | 方針 |
|---|---|
| 既存データ | 破棄してよい（Issue 確定）。`NULL` クリアのみは不採用（列ごと不要） |
| DROP | `ALTER TABLE training_log DROP COLUMN IF EXISTS avg_hr/max_hr` |
| VIEW | activity 系のみ DROP → 列 DROP → CREATE（`security_invoker` + GRANT 再現）。`garmin_daily_claude` は対象外 |
| Garmin HR 露出 | `avg_hr_garmin` パス修正 + `max_hr_garmin` 新規（確定）。他 summary キーのパス修正はしない |
| ロールバック | 新規マイグレーションで列再追加は可能だが、過去 HK 値は復元不可。Garmin archive は残る |
| 既存マイグレーション編集 | しない（適用済み `20260704063000_*` / `20260712120000_*` は履歴として維持） |

---

## アプリ側変更方針（avg/max とゾーンの切り離し）

現状 `HeartRateZoneCalculator.aggregate` は **同一ループ**で (1) 加重平均/max と (2) ゾーン秒数バケットを計算している。優先順位は「HK statistics があれば採用、無ければサンプル集計」。

切り離し後の責務:

```
WorkoutSnapshot(workout)     … 距離・カロリー等のみ（HR statistics は取らない）
        │
        ▼
WorkoutHeartRateFetcher      … 心拍サンプル取得 + ゾーン境界ロード
        │
        ▼
HeartRateZoneCalculator      … サンプル区間 → zone1..5 分のみ
        │
        ▼
WorkoutMapper / TrainingLogRecord … hr_zone_minutes (+ metadata.hr_zone_source) のみ永続化
```

ポイント:

- サンプル取得フロー自体は残す（ゾーン算出に必須）
- avg/max 用の statistics 優先ロジック・加重平均・サンプル max は削除
- `enrich` 失敗時はゾーン無しで他メトリクスのみ同期（avg/max は残さない）

---

## テスト計画

| 種別 | 内容 |
|---|---|
| ユニット | `HeartRateZoneCalculatorTests` — ゾーン境界・滞在時間・クリップ・空サンプル。avg/max アサーション削除 |
| ユニット | `WorkoutMapperTests` — avg/max 除去後も discipline / dataSource / hrZoneMinutes パススルーが通る。`testEncodeExcludesManualAnnotationColumns` は手動注釈列除外のまま（avg/max 検証は追加しない） |
| ユニット | `GarminSyncRequestRecordTests` — fixture コンパイルのみ（型追随） |
| DB | マイグレーション適用後 `information_schema.columns` で列不在 |
| DB | `SELECT activity_name, avg_hr_garmin, max_hr_garmin FROM garmin_activity_claude_summary LIMIT 3` が成功し、training_log 由来 `avg_hr` が無く、Garmin HR が数値であること |
| 実機 | 既存ワークアウト再同期 → `hr_zone_minutes` 更新、`avg_hr`/`max_hr` 列なし |

---

## リスクと注意点

1. **PostgREST upsert はペイロード列のみ更新**  
   アプリから列を外しても既存値は残る。過去データ消去は **DROP 必須**。

2. **デプロイ順序**  
   マイグレーション先行禁止。アプリ更新 → マイグレーション適用。

3. **VIEW 依存**  
   `DROP COLUMN` 前に `garmin_activity_claude` / `garmin_activity_claude_summary` を落とすこと。GRANT・`security_invoker` の再現漏れに注意。`garmin_daily_claude` は落とさない。

4. **パス修正の副作用（意図した改善）**  
   現行 `avg_hr_garmin` は常に NULL。`summaryDTO` パスに直すと値が入る。加えて `max_hr_garmin` が新規列として見える。Claude / 手動 SQL が旧カラム名 `avg_hr`（training_log）を参照している場合は失敗する → `avg_hr_garmin` / `max_hr_garmin` へ切替。  
   あわせて `avg_hr_garmin` の型は従来の text 相当から `numeric` キャストに揃える（`distance_m` と同方針）。

5. **ゾーン算出コストは維持**  
   サンプル取得は残る。本 Issue で同期を軽くする意図はない。

6. **`HeartRateZoneBoundaries` の maxHr**  
   名前が似ているがゾーン境界用。誤って削除しないこと。

---

## 受け入れ条件（Issue AC 対応）

- [ ] HealthKit 同期後、新規・再同期行に `avg_hr` / `max_hr` が存在しない（列 DROP 済み）
- [ ] `hr_zone_minutes` は従来どおり同期される
- [ ] VIEW が壊れず、Garmin archive の `summaryDTO` 経由で `avg_hr_garmin` / `max_hr_garmin` を参照できる
- [ ] 関連ユニットテスト・ドキュメントが更新されている

---

## 検証手順

1. **ユニットテスト**  
   Xcode で `MyVitalRelayTests` を実行しグリーンであること。

2. **マイグレーション**  
   ```sql
   SELECT column_name
   FROM information_schema.columns
   WHERE table_schema = 'public'
     AND table_name = 'training_log'
     AND column_name IN ('avg_hr', 'max_hr', 'hr_zone_minutes');
   -- 期待: hr_zone_minutes のみ
   ```

3. **VIEW**  
   ```sql
   SELECT activity_name, avg_hr_garmin, max_hr_garmin, training_log_id
   FROM garmin_activity_claude_summary
   LIMIT 3;
   -- エラーなし。リンク済み行で Garmin HR が数値であること
   -- training_log 由来の avg_hr 列は存在しないこと
   ```

4. **実機再同期**  
   既存ワークアウトを手動同期し、当該 `training_log` 行の `hr_zone_minutes` が埋まり、avg/max 列がスキーマ上存在しないこと。

5. **回帰**  
   Life Fitness 由来（ゾーン無し）・Garmin 由来（ゾーンあり）の両方で upsert が成功すること。

---

## 参考（調査で確認した事実）

- Issue #27 本文の下流依存リストとリポジトリ調査結果は一致
- `training_log` を参照する public VIEW は `garmin_activity_claude_summary` のみ
- Garmin archive の HR は `summary.summaryDTO` 配下（トップレベル `averageHR` は NULL）
- Garmin sync はもともと `training_log.avg_hr` / `max_hr` を更新していない

---

## Appendix A: マイグレーション SQL 草案

ベース: `supabase/migrations/20260712120000_garmin_sync_claude_access.sql` の Claude 向け VIEW 定義。  
ファイル名例: `supabase/migrations/20260731120000_drop_training_log_avg_max_hr.sql`

```sql
-- training_log から HealthKit 由来の avg_hr / max_hr を削除し、
-- Claude 向け activity VIEW を Garmin archive (summaryDTO) 参照に切替する。
-- Issue #27
--
-- 注意:
-- - garmin_daily_claude は触らない
-- - distance / cadence / power 等の summary キーのパスは変更しない（HR のみ）

DROP VIEW IF EXISTS garmin_activity_claude;
DROP VIEW IF EXISTS garmin_activity_claude_summary;

ALTER TABLE training_log DROP COLUMN IF EXISTS avg_hr;
ALTER TABLE training_log DROP COLUMN IF EXISTS max_hr;

CREATE VIEW garmin_activity_claude_summary
WITH (security_invoker = true)
AS
SELECT
  a.id,
  a.user_id,
  a.garmin_activity_id,
  a.activity_type_key,
  a.activity_name,
  a.start_time_local,
  a.duration_sec,
  a.synced_at,
  a.sync_status,
  a.training_log_id,
  t.date AS training_log_date,
  t.discipline,
  t.distance_km,
  -- t.avg_hr は削除済み
  t.rpe,
  t.condition_notes,
  (a.summary->'summaryDTO'->>'averageHR')::numeric AS avg_hr_garmin,
  (a.summary->'summaryDTO'->>'maxHR')::numeric AS max_hr_garmin,
  (a.summary->>'distance')::numeric AS distance_m,
  a.summary->>'averageRunningCadenceInStepsPerMinute' AS cadence_spm,
  a.summary->>'avgPower' AS avg_power_w,
  a.summary->>'aerobicTrainingEffect' AS aerobic_te,
  a.summary->>'activityTrainingLoad' AS training_load,
  (a.fit_parsed = '{}'::jsonb AND a.fit_parsed_storage_path IS NOT NULL) AS fit_parsed_in_storage,
  (a.api_responses = '{}'::jsonb AND a.api_json_storage_path IS NOT NULL) AS api_responses_in_storage
FROM garmin_activity_archive a
LEFT JOIN training_log t ON t.id = a.training_log_id;

CREATE VIEW garmin_activity_claude
WITH (security_invoker = true)
AS
SELECT
  s.*,
  a.summary,
  a.fit_parsed,
  a.api_responses,
  a.fit_storage_path,
  a.fit_parsed_storage_path,
  a.api_json_storage_path
FROM garmin_activity_claude_summary s
JOIN garmin_activity_archive a ON a.id = s.id;

GRANT SELECT ON garmin_activity_claude_summary TO authenticated;
GRANT SELECT ON garmin_activity_claude TO authenticated;
```
