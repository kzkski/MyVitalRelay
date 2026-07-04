# MyVitalRelay

HealthKit（読み取り専用）→ Supabase `training_log`（書き込み専用）の一方向リレーを行うiOSアプリ。
ワークアウト（Garmin外走・Life Fitnessジム）を `HKAnchoredObjectQuery` の差分同期で取得し、
`healthkit_uuid` をキーに冪等アップサートする。設計背景は `docs/implementation-plan.md` を参照。

## セットアップ（Mac）

```bash
brew install xcodegen
git clone <this repo> && cd MyVitalRelay
xcodegen generate
open MyVitalRelay.xcodeproj
```

1. ターゲット MyVitalRelay の Signing & Capabilities で自分のチームを選択（バンドルIDは既定で `tv.civictech.MyVitalRelay`。変える場合は project.yml の `bundleIdPrefix`）。
2. 実機（iPhone）を接続して Run。**HealthKitはシミュレータでは実データが取れないため、検証は実機前提。**
3. 初回起動で Supabase アカウント（ケトログと同じメール＋パスワード）でサインイン → HealthKitの許可ダイアログで全項目を許可。

SupabaseのURL・publishable keyは `MyVitalRelay/Config/SupabaseConfig.swift` に埋め込み済み（RLS前提の公開値）。

## テスト

マッピングロジック（WorkoutMapper）は純粋関数なのでシミュレータで実行可：

```bash
xcodebuild test -scheme MyVitalRelay -destination 'platform=iOS Simulator,name=iPhone 16'
```

## 実機検証チェックリスト

1. サインイン → HealthKit一括認可が通る
2. Life Fitness由来ワークアウトが同期される（`data_source='life_fitness'`、心拍NULL、距離・カロリーあり）
3. Garmin由来ワークアウトが同期される（`data_source='garmin'`、心拍・獲得標高あり）
4. 「今すぐ同期」を何度押しても重複レコードが増えない（healthkit_uuid冪等性）
5. アプリをバックグラウンドに置いたまま新規ワークアウトがHealthKitに書かれると自動同期される（OSの裁量で遅延あり。フォアグラウンド復帰時にも必ず同期が走る）
6. Supabase上で `metadata` 列（source_name / source_bundle_id / indoor_workout）を確認し、
   Life Fitnessの実際の書き込み項目と `HKMetadataKeyIndoorWorkout` の有無を記録（引き継ぎ資料6節の未検証事項の解消）

### Life Fitnessが `manual` として同期されてしまった場合

ソース判定は `MyVitalRelay/Mapping/WorkoutMapper.swift` の `dataSource(sourceName:bundleId:)` にある。
同期済みレコードの `metadata.source_bundle_id` の実値を見て、判定条件に1行追加すればよい。

## 既知の制限・将来対応

- `cadence`: HKWorkout単体からは取得不可のため当面NULL。将来はワークアウト時間帯のstepCountサンプル集計で対応可能。
- `hr_zone_minutes`: iOS 27の `HKWorkoutZoneGroup` 一般提供後に実装。
- 体重・体脂肪率・睡眠の同期移管（現在はiOS Shortcuts自動化）: HealthKit認可は先行取得済みなので、将来は同期ロジック追加のみで移管可能。
- `rpe` / `condition_notes` / 手動記録（`data_source='manual'`）: チャット上のClaudeが記入する運用で、本アプリの対象外。
