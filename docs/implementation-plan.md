# MyVitalRelay 実装計画

作成日: 2026-07-04
前提資料: MyVitalRelay 実装引き継ぎ資料（2026-07-04版）

## 0. 確定済みの前提（事前確認の回答）

| 論点 | 決定 |
|---|---|
| Xcodeプロジェクト管理 | **XcodeGen**。リポジトリには `project.yml`＋Swiftソースのみを置き、Mac側で `xcodegen generate` して .xcodeproj を生成する |
| Supabase認証 | **メール＋パスワード**（supabase-swift SDK）。ケトログと同じSupabaseプロジェクト・同じユーザー（`77ea5bd6-...`）でサインイン |
| `training_log` DDL適用 | **実装フェーズ冒頭**に Supabase MCP 経由でマイグレーションとして本番適用。SQLファイルもリポジトリに保存 |
| MVPスコープ | **HealthKitワークアウト同期のみ**＋同期状況確認の最小UI。手動記録（筋トレ等）UI・ダッシュボードは対象外。`rpe`/`condition_notes`/`srpe` はチャット上のClaudeが記入する運用でアプリ対象外 |

追加の技術前提:

- **SwiftUI／Swift 5.10+／最低デプロイターゲット iOS 17**（async/await・Observation前提。Kazukiさんの実機は最新iOSの想定だが、iOS 27専用API `HKWorkoutZoneGroup` には依存しない → `hr_zone_minutes` は当面常にNULL）
- 依存パッケージは **supabase-swift（SPM）のみ**。それ以外の外部依存は持たない
- この環境（Linux）ではビルド・実機検証ができないため、**ビルドと実機テストはKazukiさんのMac／iPhoneで実施**。そのための手順書（README）を成果物に含める

## 1. フェーズ構成

### フェーズ1: DBマイグレーション（このセッションで完結）

1. `supabase/migrations/xxxx_create_training_log.sql` を作成し、Supabase MCP（`apply_migration`）で本番プロジェクト `ykcbevvorckcigwwtftw` に適用する。既存テーブルには一切触れない追加のみ。
2. 適用後に `get_advisors`（security/performance）を実行し、RLS等の警告がないことを確認する。

**引き継ぎDDLからの変更提案（1点のみ、要承認）**:

```sql
-- 引き継ぎ資料版
CREATE UNIQUE INDEX idx_training_log_hk_uuid ON training_log(healthkit_uuid)
  WHERE healthkit_uuid IS NOT NULL;

-- 提案: 部分インデックスではなく通常のUNIQUE制約にする
ALTER TABLE training_log ADD CONSTRAINT training_log_healthkit_uuid_key UNIQUE (healthkit_uuid);
```

理由: PostgresのUNIQUE制約はNULL同士を重複とみなさないため、`healthkit_uuid` がNULLの手動レコードは通常のUNIQUE制約でも何件でも入る（部分インデックスと同じ意味論）。一方、PostgREST（supabase-swift）の `upsert(onConflict: "healthkit_uuid")` は部分インデックスでは競合推論に失敗するため、**通常のUNIQUE制約でないとアプリ側の冪等アップサートが書けない**。意味論は変えずに実装可能性のためだけの変更。

その他のDDL（カラム構成・CHECK制約・RLSポリシー・`(user_id, date)` インデックス・生成列 `srpe`）は引き継ぎ資料の最終スキーマをそのまま使う。`updated_at` の自動更新はトリガーを追加せず、アプリのアップサート時に明示的にセットする。

### フェーズ2: リポジトリ雛形＋アプリ実装（このセッションで完結）

ディレクトリ構成:

```
MyVitalRelay/
├── project.yml                  # XcodeGen定義（ターゲット・entitlements・Info.plistキー）
├── .gitignore
├── README.md                    # Mac側セットアップ〜実機検証手順
├── supabase/migrations/         # フェーズ1のSQL
├── MyVitalRelay/
│   ├── App/                     # @main、ルートビュー切替（未サインイン→サインイン画面）
│   ├── Config/                  # SupabaseのURL・publishable key（RLS前提の公開値）
│   ├── HealthKit/
│   │   ├── HealthKitAuthorizer.swift    # 全データタイプ一括認可要求
│   │   ├── WorkoutAnchorStore.swift     # HKQueryAnchorの永続化（UserDefaults）
│   │   ├── WorkoutFetcher.swift         # HKAnchoredObjectQueryによる差分取得
│   │   └── BackgroundDeliveryManager.swift  # enableBackgroundDelivery + HKObserverQuery
│   ├── Mapping/
│   │   └── WorkoutMapper.swift          # HKWorkout → TrainingLogRecord 変換（純粋ロジック）
│   ├── Sync/
│   │   ├── TrainingLogRecord.swift      # training_log行のCodable表現
│   │   └── SyncEngine.swift             # 取得→変換→アップサート→アンカー前進の統括
│   ├── Supabase/
│   │   ├── SupabaseClientProvider.swift
│   │   └── AuthService.swift            # メール＋パスワードサインイン、セッション保持
│   └── UI/
│       ├── SignInView.swift
│       └── SyncStatusView.swift         # 最終同期日時・直近同期レコード一覧・手動同期ボタン・エラー表示
└── MyVitalRelayTests/
    └── WorkoutMapperTests.swift         # マッピングの単体テスト（Mac側で実行）
```

主要な実装方針:

- **HealthKit認可**: `requestAuthorization(toShare: [], read: ...)` で、ワークアウト・アクティブカロリー・心拍数・歩行/走行距離・自転車距離・水泳距離・ストローク数・体重・体脂肪率・睡眠分析を初回に一括要求（引き継ぎ2.3節どおり。体重等はMVPでは同期しないが、将来のdaily_log同期移管時に再認可フローを踏まなくて済むよう先に取っておく）。
- **差分同期**: `HKAnchoredObjectQuery`（対象: `HKWorkoutType`）。アンカーは**Supabaseへの書き込みが全件成功したときのみ前進**させる。失敗時は前進させず次回リトライ（アップサートなので重複しない）。
- **バックグラウンド同期**: `enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)`＋`HKObserverQuery`。観測コールバック内で同期を実行し、完了後に `completionHandler()` を呼ぶ。entitlement `com.apple.developer.healthkit.background-delivery` を project.yml で定義。
- **書き込み**: supabase-swift の `upsert(onConflict: "healthkit_uuid")`。認証済みユーザーのJWTで実行し、`service_role` は使わない。

`WorkoutMapper` のマッピング仕様（要点）:

| training_log列 | 取得元 |
|---|---|
| `healthkit_uuid` | `HKWorkout.uuid` |
| `data_source` | `sourceRevision.source` のバンドルID/名称で判定。Garmin Connect → `garmin`、Life Fitness系 → `life_fitness`、**それ以外 → `manual`**（生のソース名を `metadata.source_name` に必ず保存し、判定漏れを後から発見できるようにする） |
| `discipline` | `workoutActivityType` から: running/**walking** → `run`（歩行距離も走行距離扱いというKazukiさん方針に合わせる）、cycling → `bike`、swimming → `swim`、traditionalStrengthTraining/functionalStrengthTraining → `strength`、その他 → `other`。デフォルト値なし・毎回明示 |
| `workout_type` | `workoutActivityType` の文字列生値 |
| `date` | `startDate` を **Asia/Tokyo** で日付化 |
| `start_time` / `end_time` / `duration_min` | `startDate` / `endDate` / `duration`（分換算） |
| `distance_km` | distanceWalkingRunning / distanceCycling / distanceSwimming の統計値（種目により選択、合算値をそのまま格納） |
| `avg_speed_kmh` | distance_km ÷ duration から算出（distanceがNULLならNULL） |
| `calories_burned` | activeEnergyBurned 統計値 |
| `avg_hr` / `max_hr` | heartRate 統計値（Life Fitness由来は自然にNULL） |
| `elevation_gain_m` | `HKMetadataKeyElevationAscended`（なければNULL） |
| `stroke_count` | swimmingStrokeCount 統計値（水泳のみ） |
| `cadence` / `power_watts` / `stroke_style` / `hr_zone_minutes` | **MVPでは常にNULL**（cadenceはHKWorkoutから直接取れないため、将来stepCountサンプル集計で対応する余地をREADMEに記録） |
| `equipment` / `surface` / `rpe` / `condition_notes` / `notes` | NULL（チャット運用・手動記入領域） |
| `metadata` | `source_name`・`source_bundle_id`・`HKMetadataKeyIndoorWorkout` の実値など、未マッピング情報の受け皿。**引き継ぎ6節の未検証事項（Life Fitnessの書き込み項目・indoorメタデータの実態）をここに生ログとして貯めて実機確認に使う** |

### フェーズ3: 実機検証（Kazukiさん作業、READMEに手順書化）

こちらでは検証できないため、以下のチェックリストをREADMEに含めて引き渡す:

1. Mac: `brew install xcodegen` → `xcodegen generate` → 署名チーム設定 → 実機ビルド
2. 初回起動: サインイン → HealthKit一括認可
3. Life Fitness由来ワークアウトが同期されること（`data_source='life_fitness'`、心拍NULL、距離・カロリーが入る）
4. Garmin由来ワークアウトが同期されること（`data_source='garmin'`、心拍・獲得標高が入る）
5. 手動同期ボタン→再実行しても重複レコードが増えないこと（healthkit_uuid冪等性）
6. アプリをバックグラウンドに置いた状態で新規ワークアウト書き込み→自動同期されること
7. Supabase上で `metadata` 列を確認し、Life Fitnessの実際の書き込み項目・indoorメタデータの有無を記録（引き継ぎ6節の未検証事項の解消）

### フェーズ4: 体組成・睡眠の生データ同期（拡張案・2026-07-04 確定）

フェーズ2（ワークアウト同期）完了後の拡張。現行の `daily_log` は**過渡的な集計テーブル**であり、HealthKit 生データの置き場ではない。MyVitalRelay の責務は **HealthKit → 生データテーブルへのリレー**までとし、日次集計・振り返りはケトログ AI アドバイザーとの対話や SQL View で任意のタイミングに行う。

#### 4.0 設計方針（3層）

| 層 | 役割 | 担当 |
|---|---|---|
| **生データ** | HealthKit の事実をそのまま保存（1サンプル/1セグメント = 1行） | MyVitalRelay（自動同期） |
| **集計** | 日次平均・睡眠合計などの要約 | 任意タイミング（View / バッチ / AI対話） |
| **解釈** | PFC・notes・振り返り | ケトログ + AI |

**採用しない案:**

- 体重測定を `training_log` に載せる — ワークアウトと意味論が異なりクエリが汚れるため非採用。体重計に乗る行為は `body_composition_sample` でイベントとして記録する。
- 現 `daily_log` へ HealthKit 値を直接 upsert し続ける — PFC・notes と混在し部分更新が複雑。HK 由来データの正は新テーブルに移す。

**現 `daily_log` の扱い:**

- 当面は PFC・`notes` 等のケトログ入力先として残す（または後継の `daily_summary` に移行）。
- `weight_kg` / `sleep_hours` / `calories_burned` 等の HK 列への書き込みは Shortcuts 停止後にやめる。
- 旧形式の `sleep_hours`（例: `7:57:00`）は集計 View や AI が出力する互換形式として再現可能。

#### 4.1 新規テーブル DDL（案）

`training_log` と同様、`user_id` + RLS + `healthkit_uuid` による冪等 upsert を前提とする。

```sql
-- 体重・体脂肪: 体重計に乗る1回 = 1行
CREATE TABLE body_composition_sample (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  measured_at timestamptz NOT NULL,
  date date NOT NULL,              -- measured_at を Asia/Tokyo で日付化（検索用）
  weight_kg numeric(4, 1),
  body_fat_pct numeric(4, 1),
  healthkit_uuid uuid UNIQUE,
  source_name text,
  source_bundle_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_body_composition_user_measured
  ON body_composition_sample (user_id, measured_at);

ALTER TABLE body_composition_sample ENABLE ROW LEVEL SECURITY;

CREATE POLICY "body_composition_owner_access" ON body_composition_sample
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 睡眠: HealthKit sleepAnalysis セグメント1件 = 1行
CREATE TABLE sleep_segment (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  start_time timestamptz NOT NULL,
  end_time timestamptz NOT NULL,
  stage text NOT NULL,             -- core / deep / rem / unspecified（asleep 系のみ。awake・inBed は同期しない）
  duration_sec integer NOT NULL,
  healthkit_uuid uuid UNIQUE,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_sleep_segment_user_start
  ON sleep_segment (user_id, start_time);

ALTER TABLE sleep_segment ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sleep_segment_owner_access" ON sleep_segment
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
```

**将来（任意）: `daily_summary`**

ケトログの日次キャッシュ。正は上記生データ + 食事記録。AI 対話やダッシュボード用に再計算可能なスナップショットとして後から追加してよい（フェーズ4の必須スコープ外）。

#### 4.2 同期トリガー（MyVitalRelay を普段開かない前提）

ワークアウトと同型の **HealthKit Background Delivery + HKObserverQuery** を主トリガーとする。ユーザーが MyVitalRelay の UI を開く必要はない。

| データ | HK タイプ | Background Delivery 頻度 | 主トリガー |
|---|---|---|---|
| ワークアウト | `workoutType` | `.immediate` | HK 更新時（Garmin / Life Fitness 等）— **実装済み** |
| 体重・体脂肪 | `bodyMass`, `bodyFatPercentage` | `.immediate` または `.hourly` | 体重計測定サンプル追加時 |
| 睡眠 | `sleepAnalysis` | `.daily` | 昨晩分が HealthKit に書き込まれた時（Watch 同期待ち後） |

**フォールバック（副次）:**

1. **フォアグラウンド復帰時** — `RootView` の `scenePhase == .active` で全種別を差分同期（取りこぼし回収）。OS がバックグラウンド配信を遅延・スキップした場合の保険。
2. **手動「今すぐ同期」** — デバッグ・検証用。

**Shortcuts との違い:**

- Shortcuts: **時刻スケジュール**（毎朝「前日分」を送信）
- MyVitalRelay: **イベント駆動**（HealthKit にデータが入ったらリレー）。配信タイミングは OS の裁量で数分〜数時間ずれることがある。

**初回・運用上の前提:**

- 初回サインイン時の `SyncEngine.start()` で Background Delivery を各タイプに登録する（1回必要）。
- アプリを**強制終了**すると Background Delivery が止まることがあり、次回起動まで同期されない。リレーアプリとしては「たまに起動して回収」が現実的なフォールバック。
- 低電力モード等で遅延しうる（フェーズ2と同じリスク）。

#### 4.3 アプリ実装方針

`training_log` 同期パターンを踏襲: **HKAnchoredObjectQuery 差分取得 → 変換 → upsert → アンカー前進（書き込み成功時のみ）**。

```
MyVitalRelay/
├── HealthKit/
│   ├── BackgroundDeliveryManager.swift   # workout に加え bodyMass / sleepAnalysis を登録
│   ├── BodyCompositionFetcher.swift      # HKAnchoredObjectQuery（quantity samples）
│   ├── BodyCompositionAnchorStore.swift
│   ├── SleepSegmentFetcher.swift         # HKAnchoredObjectQuery（category samples）
│   └── SleepSegmentAnchorStore.swift
├── Mapping/
│   ├── BodyCompositionMapper.swift       # 純粋関数 + 単体テスト
│   └── SleepSegmentMapper.swift
├── Sync/
│   ├── BodyCompositionSampleRecord.swift
│   ├── SleepSegmentRecord.swift
│   ├── BodyCompositionSyncEngine.swift   # または SyncEngine に統合
│   └── SleepSegmentSyncEngine.swift
└── SyncEngine.swift                      # sync() 内で workout → body → sleep の順に呼ぶ
```

**マッピング要点:**

| テーブル列 | 取得元 |
|---|---|
| `body_composition_sample.healthkit_uuid` | `HKQuantitySample.uuid` |
| `measured_at` | サンプルの `startDate` |
| `date` | `measured_at` を **Asia/Tokyo** で日付化 |
| `weight_kg` | `bodyMass`（kg 換算） |
| `body_fat_pct` | `bodyFatPercentage`（% 換算。サンプルに無ければ NULL） |
| `sleep_segment.healthkit_uuid` | `HKCategorySample.uuid` |
| `start_time` / `end_time` | セグメントの開始・終了 |
| `stage` | `HKCategoryValueSleepAnalysis` を文字列化 |
| `duration_sec` | `endDate - startDate` |

**日次集計（アプリ外）の例:**

- その日の平均体重: `AVG(weight_kg) WHERE date = ?`
- その日の睡眠合計: `SUM(duration_sec) WHERE end_time の JST 日付 = ?`（帰属ルールは AI / View 設計時に確定。実装前に Shortcuts 出力と数夜分を照合）
- 旧 `daily_log.sleep_hours` 形式 `H:MM:SS` は集計結果の表示形式として View で再現

#### 4.4 実装サブフェーズ

| サブフェーズ | 内容 |
|---|---|
| **4a** | 上記 DDL を `supabase/migrations/` に追加し本番適用。`get_advisors` 確認 |
| **4b** | `body_composition_sample` 同期（Fetcher / Mapper / SyncEngine 統合 / Background Delivery 拡張） |
| **4c** | `sleep_segment` 同期（同上） |
| **4d** | 実機検証: 体重計1回 = 1行、睡眠セグメント差分、冪等性、バックグラウンド配信 |
| **4e** | Shortcuts の HK 連携（体重・睡眠）を停止。PFC・notes はケトログ従来通り |
| **4f（任意）** | `daily_summary` View / テーブル、AI 集計ツール連携 |

#### 4.5 移行チェックリスト

1. 新テーブルに生データが入ることを確認（`2026-07-04` 前後の体重・睡眠で照合）
2. Shortcuts 停止後も HK 更新で自動同期されること（UI を開かずに）
3. 旧 `daily_log` の PFC・`notes` 列が誤って上書きされないこと
4. 強制終了 → 再起動後に取りこぼしが回収されること（フォールバック動作）

## 2. スコープ外

- Garmin/Life Fitness直接API連携（フェーズ2候補として保留のまま）
- `hr_zone_minutes` の実装（iOS 27の`HKWorkoutZoneGroup`一般提供後）
- **`daily_summary` の自動集計・AI ツール実装** — フェーズ4では生データ同期まで。集計はケトログ側で任意タイミング
- 手動記録UI・ダッシュボード・`rpe`/`condition_notes`のアプリ入力

## 3. リスクと対応

| リスク | 対応 |
|---|---|
| Life Fitnessのソース判定文字列（バンドルID）が実機確認まで不明 | 名称部分一致＋バンドルIDプレフィックスの両方で判定し、判定不能時は `manual` に落として `metadata.source_name` に生値を残す。実機確認後に判定条件を1行修正すれば済む構造にする |
| PostgRESTアップサートと部分UNIQUEインデックスの非互換 | フェーズ1の通常UNIQUE制約への変更提案で解消 |
| バックグラウンド配信はOSの裁量で遅延しうる | フォアグラウンド復帰時にも必ず差分同期を走らせる（observer任せにしない） |
| Linux環境でSwiftのコンパイル検証ができない | ロジックの中核（WorkoutMapper）を純粋関数に寄せて単体テストを同梱し、Mac側で `xcodebuild test` を一発実行できるようREADMEに明記 |
| 睡眠の日次帰属（どの暦日に何時間眠ったか）が Shortcuts と微妙にずれる可能性 | フェーズ4d で数夜分を並べて照合。生データは `sleep_segment` にセグメント単位で保持するため、帰属ルール変更は View / 集計側のみで吸収可能 |
| MyVitalRelay を強制終了すると Background Delivery が止まる | 次回起動時の `start()` で再登録。フォアグラウンド復帰同期で取りこぼし回収 |
| 旧 `daily_log` に HK 列と PFC 列が混在 | フェーズ4以降 HK は新テーブルのみ。`daily_log` への HK 書き込みは行わない |
