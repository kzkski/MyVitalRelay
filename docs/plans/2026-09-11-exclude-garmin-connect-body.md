# 実装計画: Garmin Connect 体組成の除外と汚染データの掃除

- Issue: [#38](https://github.com/kzkski/MyVitalRelay/issues/38)
- 作成日: 2026-09-11
- 状態: **実装中**（`fix/38-exclude-garmin-connect-body`）
- 前提: Garmin Connect のヘルスケア体重書き込みは手作業でオフ済み。Connect 75 行の削除は承認済み。

## 設計ロック

| 項目 | 決定 |
|---|---|
| 判定キー | `source_bundle_id = 'com.garmin.connect.mobile'` |
| ソース方針 | denylist（Eufy / Omron は残す） |
| 取り込み | `BodyCompositionMapper.record` を Optional + `SyncEngine` の `compactMap`。Fetcher predicate は維持 |
| 下流 | `daily_log` / `interval-icu-sync` / Python backfill でも同じ denylist |
| 既存行 | マイグレーションで冪等 DELETE。CI が競合したら手動適用 |
| PR | MyVitalRelay の 1 PR |
| やらない | 論理 UNIQUE、`deletedObjects`、workout の Garmin 判定、`queries.md`（プラグイン未インストール） |

## 変更ファイル

- iOS: `BodyCompositionMapper.swift` / `SyncEngine.swift` / `BodyCompositionMapperTests.swift`
- ICU: `interval-icu-sync/lib.ts` / `index.ts` / `lib.test.ts`
- backfill: `scripts/interval_icu_backfill_lib.py` / `interval_icu_backfill.py` / `tests/test_interval_icu_backfill_lib.py`
- DB: `20260911120000_daily_log_exclude_garmin_connect_body.sql` / `20260911130000_delete_garmin_connect_body_samples.sql`
- docs: 本ファイル / `docs/interval-icu-sync-ops.md` / `README.md`

## ロールアウト

1. PR merge → Prod DB Migration（VIEW + DELETE + 2026-09-11 再キュー）
2. 適用失敗時は同じ SQL を手動実行し、結果を確認する
3. `supabase functions deploy interval-icu-sync`
4. iOS をビルドして端末へ
5. 検証: Connect 0 行、`daily_log` 2026-09-11 が 64.3 / 18.7

## 本番適用メモ（2026-09-11）

CI の `schema_migrations` 競合を避けるため、DDL/DML は merge 前に手動実行済み。

- `daily_log` VIEW: Connect 除外を適用。2026-09-11 は 64.3 / 18.7
- Connect 75 行 DELETE 済み（Eufy 377 / Omron 84 は残存）
- `interval_icu_sync_request` 2026-09-11 `manual` → `complete`
- merge 後の `db push` は CREATE OR REPLACE / 冪等 DELETE で再実行されてよい。enqueue は pending が無ければもう 1 回 INSERT されうる（同じ wellness PUT）
