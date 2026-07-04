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

## 2. スコープ外（引き継ぎ資料の決定に従い、再検討しない)

- Garmin/Life Fitness直接API連携（フェーズ2候補として保留のまま）
- `hr_zone_minutes` の実装（iOS 27の`HKWorkoutZoneGroup`一般提供後）
- daily_log系（体重・睡眠・消費カロリー）の同期移管 — 現行のiOS Shortcuts自動化を継続。認可だけ先行取得しておく
- 手動記録UI・ダッシュボード・`rpe`/`condition_notes`のアプリ入力

## 3. リスクと対応

| リスク | 対応 |
|---|---|
| Life Fitnessのソース判定文字列（バンドルID）が実機確認まで不明 | 名称部分一致＋バンドルIDプレフィックスの両方で判定し、判定不能時は `manual` に落として `metadata.source_name` に生値を残す。実機確認後に判定条件を1行修正すれば済む構造にする |
| PostgRESTアップサートと部分UNIQUEインデックスの非互換 | フェーズ1の通常UNIQUE制約への変更提案で解消 |
| バックグラウンド配信はOSの裁量で遅延しうる | フォアグラウンド復帰時にも必ず差分同期を走らせる（observer任せにしない） |
| Linux環境でSwiftのコンパイル検証ができない | ロジックの中核（WorkoutMapper）を純粋関数に寄せて単体テストを同梱し、Mac側で `xcodebuild test` を一発実行できるようREADMEに明記 |
