# MyVitalRelay

HealthKit（読み取り専用）→ Supabase（書き込み専用）の一方向リレーを行うiOSアプリ。
ワークアウト・体組成・睡眠を `HKAnchoredObjectQuery` の差分同期で取得し、
`healthkit_uuid` をキーに冪等アップサートする。設計背景は `docs/implementation-plan.md` を参照。

| HealthKit | Supabase テーブル |
|---|---|
| ワークアウト | `training_log` |
| 体重・体脂肪 | `body_composition_sample` |
| 睡眠セグメント | `sleep_segment` |
| 日次カロリー | `daily_activity_summary` |

Garmin 詳細（FIT / API JSON）同期は **Phase 1** で追加予定。設計は `docs/garmin-api-sync-investigation.md`、Mac 検証手順は `docs/garmin-phase1-mac-checklist.md`。

## セットアップ（Mac）

```bash
brew install xcodegen
git clone <this repo> && cd MyVitalRelay
xcodegen generate
open MyVitalRelay.xcodeproj
```

1. ターゲット MyVitalRelay の Signing & Capabilities で自分のチームを選択（バンドルIDは既定で `tv.civictech.MyVitalRelay`。変える場合は project.yml の `bundleIdPrefix`）。
2. 実機（iPhone）を接続して Run。**HealthKitはシミュレータでは実データが取れないため、検証は実機前提。**
3. 初回起動で **Googleでサインイン**（ケトログと同じGoogleアカウント）→ HealthKitの許可ダイアログで全項目を許可。

### Google認証のSupabase設定（初回のみ）

1. [Authentication → Providers → Google](https://supabase.com/dashboard/project/ykcbevvorckcigwwtftw/auth/providers) で **Google を有効化**
2. Google Cloud Console で **Web application** の OAuth クライアントを作成し、Client ID / Secret を Supabase に登録
3. [Authentication → URL Configuration](https://supabase.com/dashboard/project/ykcbevvorckcigwwtftw/auth/url-configuration) の **Redirect URLs** に以下を追加:
   - `tv.civictech.myvitalrelay://login-callback`
4. アプリを再ビルドして「Googleでサインイン」を試す

メール＋パスワードでのサインインも残しているが、Email provider が無効な場合は Google 認証を使うこと。

SupabaseのURL・publishable keyは `MyVitalRelay/Config/SupabaseConfig.swift` に埋め込み済み（RLS前提の公開値）。

## テスト

マッピングロジック（WorkoutMapper）は純粋関数なのでシミュレータで実行可：

```bash
xcodebuild test -scheme MyVitalRelay -destination 'platform=iOS Simulator,name=iPhone 16'
```

## DBマイグレーション

### フェーズ4（体組成・睡眠）

`supabase/migrations/20260704100000_create_body_composition_and_sleep.sql` は
2026-07-04 に Supabase 本番へ適用済み。

### Garmin 詳細同期（Phase 1）

`supabase/migrations/20260712120000_garmin_sync_claude_access.sql`

- main マージ後: GitHub Actions **Prod DB Migration** が自動実行（`PROD_DATABASE_URL` Secret 要）
- 手動: `supabase db push --db-url "$PROD_DATABASE_URL"`

## Garmin 同期 Phase 1 検証

Mac + 実機での手順: **`docs/garmin-phase1-mac-checklist.md`**

1. マイグレーション適用
2. GHA Secrets 設定
3. `garmin_export_samples.py` で Garmin login 確認
4. 実機で同期 → `garmin_sync_request` 投入確認
5. **Garmin Sync** workflow 手動実行 → `garmin_activity_archive` 確認

## 実機検証チェックリスト

### ワークアウト（フェーズ2）
1. サインイン → HealthKit一括認可が通る
2. Life Fitness由来ワークアウトが同期される（`data_source='life_fitness'`、心拍NULL、距離・カロリーあり）
3. Garmin由来ワークアウトが同期される（`data_source='garmin'`、心拍・獲得標高あり）
4. 「今すぐ同期」を何度押しても重複レコードが増えない
   （論理キー `(start_time, end_time, workout_type)` による upsert 冪等性。
   Garmin 等で healthkit_uuid が差し替わっても1行に収まり、
   会話で追記した rpe / condition_notes / surface / notes / equipment が保持される。
   削除通知の反映は upsert 後・追記列がすべて NULL の行に限定 — Issue #12）
5. アプリをバックグラウンドに置いたまま新規ワークアウトがHealthKitに書かれると自動同期される（OSの裁量で遅延あり。フォアグラウンド復帰時にも必ず同期が走る）
6. Supabase上で `metadata` 列（source_name / source_bundle_id / indoor_workout）を確認し、
   Life Fitnessの実際の書き込み項目と `HKMetadataKeyIndoorWorkout` の有無を記録

### Garmin 詳細同期（Phase 1）

11. Garmin ワークアウト同期後、`garmin_sync_request` に `trigger_source=healthkit` の行が入る（マイグレーション適用後）
12. GitHub Actions **Garmin Sync** 実行後、`garmin_activity_archive` に FIT データが入る

詳細手順: `docs/garmin-phase1-mac-checklist.md`

### 体組成・睡眠（フェーズ4）
7. 体重計測定1回が `body_composition_sample` に1行入る（体重・体脂肪は別 UUID になりうる）
8. 睡眠セグメント（core/deep/rem/unspecified）が `sleep_segment` に入る（awake/inBed は同期されない）
9. 体組成・睡眠も「今すぐ同期」で冪等であること
10. Shortcuts の体重・睡眠 HK 連携を停止し、PFC・notes はケトログ従来通り

### Life Fitnessが `manual` として同期されてしまった場合

ソース判定は `MyVitalRelay/Mapping/WorkoutMapper.swift` の `dataSource(sourceName:bundleId:)` にある。
同期済みレコードの `metadata.source_bundle_id` の実値を見て、判定条件に1行追加すればよい。

## 既知の制限・将来対応

- `cadence`: HKWorkout単体からは取得不可のため当面NULL。将来はワークアウト時間帯のstepCountサンプル集計で対応可能。
- `hr_zone_minutes`: ワークアウト時間帯の心拍サンプルをゾーン別に集計して同期。境界は年齢ベース（生年月日取得不可時は35歳相当の固定値）。`metadata.hr_zone_source` に境界ソース（`age_based` / `fixed_default`）を記録。
- 体組成・睡眠はフェーズ4で同期実装済み。Shortcuts の HK 連携停止（フェーズ4e）は手動で実施すること。
- `rpe` / `condition_notes` / 手動記録（`data_source='manual'`）: チャット上のClaudeが記入する運用で、本アプリの対象外。
