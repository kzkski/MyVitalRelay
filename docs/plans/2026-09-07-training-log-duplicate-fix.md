# 実装計画: training_log NULL キー重複の恒久修正

- Issue: [#33](https://github.com/kzkski/MyVitalRelay/issues/33)
- 作成日: 2026-09-07
- 状態: **実装可（親レビュー完了）**
- 関連（退行させない）:
  - [#12](https://github.com/kzkski/MyVitalRelay/issues/12) UUID 差し替え + 注釈列付き行の削除保護
  - [#28](https://github.com/kzkski/MyVitalRelay/issues/28) garmin `calories_burned` キー省略 + `apply_garmin_calories_to_training_log`

---

## レビュー反映

### 親 1 周目（2026-09-07）

| 指摘 / 決定 | 反映 |
|---|---|
| 注釈 NULL クリア API | **今イテレーションに含めない**。引数 NULL = 列を触らない |
| `link_garmin` マップ条件追加 | **完全に後回し**（Appendix C / 将来）。PR3 必須外 |
| 未知 `activity_type_key` | **INSERT 拒否**（例外）。マップ更新運用 |
| cleanup 後 calories | マイグレーション末尾で `apply_garmin_calories_to_training_log(p_user_id)` を **呼ぶ**（keep 手編集はしない） |
| PR 分割 | **3 PR 維持**（docs → cleanup → CHECK+RPC） |
| Phase 0 と RPC の `healthkit_uuid` 矛盾 | Phase 0 必須キーを **`start_time` / `end_time` / `workout_type`（+ `data_source`）** に修正。uuid は HK 後埋め可 |
| Cleanup SQL が実装不能 | orphan 値を先保存 → UNIQUE 解放 → keep backfill → DELETE → apply。**冪等分岐**付き完全スケッチに置換（§7） |
| RPC 仕様の締め | PostgREST 例・部分更新規約・`floor_climbing`→`Other(3000)` 注記を追加 |
| テスト | 冪等 cleanup / apply ケース（**S12–S15**）を追加 |

### 親 2 周目（2026-09-07・最終）

| 指摘 / 決定 | 反映 |
|---|---|
| RPC の `p_date` 単独探索 | **削除**。解決は `p_training_log_id` / `p_garmin_activity_id` のみ |
| RPC 本体が `...` | §5 に **実装可能な plpgsql スケルトン**（map helper 含む）を追加 |
| apply の `user_id` | 本番確認済み `77ea5bd6-e655-4f45-8143-40777562ace1` を明示 |
| map helper 権限 | PR3 で `REVOKE` / `GRANT`（authenticated + service_role）を明記 |
| 残確認事項 | **dry-run orphan ID のみ**（設計未決なし） |
| 状態 | **実装可（親レビュー完了）** |

大枠（Claude ops + DB 硬保証、iOS 非変更、3 PR、cleanup / CHECK）は維持。

---

## 設計ロック（再オープン禁止）

| 項目 | 決定 |
|---|---|
| 主戦略 | **Claude 運用是正 + DB 硬保証**（iOS fuzzy merge は本丸にしない） |
| Phase 0 | 即時 ops（docs/process）: 論理キー欠落 INSERT 禁止・注釈は PATCH のみ |
| Phase 1 | ワンショット cleanup（NULL キー Claude 行 ← HK 孤児フルキー。末尾 apply calories） |
| Phase 2 / PR3 | CHECK + map helper（REVOKE/GRANT）+ `upsert_training_log_annotation`（`p_date` なし）+ docs RPC 例。**`link_garmin` 変更なし** |
| Phase 3 / PR1 | `docs/claude-garmin-access.md` に RPE 書き方（PATCH 先行、RPC は PR3 後追記可） |

**非目標（やらない）**

- iOS fuzzy merge を本丸にすること
- `distance_km` 許容誤差 dedup
- 論理 UNIQUE / SyncEngine `onConflict` の変更
- 14 日バックフィル廃止を「対策」とすること
- Garmin job に `training_log` CREATE を追加すること
- `garmin_activity_id` を `training_log` 正規キーにする再設計
- 注釈列の明示 NULL クリア API（今イテレーション）
- `link_garmin_activity_training_log` のマップ条件追加（今イテレーション）

**維持（触らない / 退行禁止）**

- Issue #12: 削除は論理キー upsert **後**、注釈列（`rpe` / `condition_notes` / `surface` / `notes` / `equipment`）がすべて NULL の行だけ DELETE
- Issue #28: garmin upsert から `calories_burned` 省略 + バッチ分割、`apply_garmin_calories_to_training_log` 経路
- `training_log_logical_unique` = `UNIQUE (user_id, start_time, end_time, workout_type)`
- SyncEngine `onConflict: "user_id,start_time,end_time,workout_type"`

---

## 1. 問題要約 + 根本原因

### 症状

同一 Garmin セッションに対し `training_log` が 2 行になる。

| 行 | 特徴 |
|---|---|
| Claude 正規行 | `rpe` / `condition_notes` あり。`start_time` / `end_time` / `healthkit_uuid` が **NULL** |
| HK 孤児行 | フル論理キーあり。注釈 NULL。`distance_km` は HK Double（例: `10.38058984375`） |

`garmin_activity_archive` は 1 行のまま、`training_log_id` は Claude 正規行を指し続ける（`link_*` は `training_log_id IS NULL` のときだけ結ぶため）。

### 根本原因（確定）

1. Claude が論理キー欠落のまま `training_log` を INSERT（RPE 付き）
2. Postgres UNIQUE は **NULL 同士を衝突させない** → NULL キー行は UNIQUE の対象外
3. iOS `SyncEngine.syncWorkouts` がフルキーで upsert → 別行 INSERT
4. 14 日バックフィルにより、孤児削除後も再出現しうる

当初の「`distance_km` 浮動小数比較で dedup すり抜け」仮説は **否定**（コード上 distance 比較は無い。距離差は書き込み元の違いの痕跡）。

### 書き込み経路（現状・変更しない部分）

```
Claude INSERT（時刻・workout_type なし・RPEあり）──► training_log（NULL キー正規）
                                                      ▲ 論理キー不一致 → 別行
iOS SyncEngine upsert（毎回 +14日 backfill）──────────┘（孤児・RPE null）

Garmin Sync Job ──► archive のみ / link・apply calories は UPDATE のみ（CREATE しない）
```

---

## 2. ゴール / 非ゴール

### ゴール

1. 新規に `data_source='garmin'` かつ `start_time`/`end_time` NULL の行を **DB で禁止**
2. Claude の主観書き込みを **既存行への注釈更新**（必要時のみフルキー INSERT）に一本化
3. 残存 NULL キー重複を掃除し、archive リンク先を生存行に維持
4. #12 / #28 / Garmin job の非 CREATE 方針を退行させない
5. docs に Claude の正しい書き方を定着

### 非ゴール

上記「設計ロック」の非目標一覧に同じ。加えて:

- iOS `SyncEngine` / `WorkoutMapper` / `TrainingLogRecord` の論理キー戦略変更
- `manual` 行の時刻 NULL 許可の撤回（筋トレ等の手動行は従来どおり時刻なし可）

---

## 3. 本番現状ノート（2026-09-07 検証）

調査手段: リポジトリ migrations + 本番 SQL（Supabase MCP）。

### NULL キー残存（2 行）

| date | Claude keep id | RPE | archive `garmin_activity_id` | archive `start_time_local` |
|---|---|---|---|---|
| 2026-08-25 | `5fa5ea06-6e10-438b-b990-8d31fc631eb1` | 2 | `24108978987` | `2026-08-25 10:26:15+00` |
| 2026-08-27 | `42c84798-81a3-4f73-9caa-868f59cc7b3d` | 4 | `24133970032` | `2026-08-27 08:35:15+00` |

両行とも `start_time` / `end_time` / `healthkit_uuid` = NULL、`workout_type='Running'`、`data_source='garmin'`。archive.`training_log_id` はそれぞれ keep id を指す。  
同一 `user_id`（本番確認済み）: `77ea5bd6-e655-4f45-8143-40777562ace1`（cleanup 末尾の `apply_garmin_calories_to_training_log` 引数）。

### 対応する HK 孤児（フルキー・注釈 null）

| date | orphan id（2026-09-07 時点） | start / end | healthkit_uuid |
|---|---|---|---|
| 2026-08-25 | `0b5c9517-7236-42fe-bbf1-48a4c5aae613` | `10:26:15`〜`11:37:26+00` | `0c1c3af6-1222-47b7-a6e9-6ff1247fc9d6` |
| 2026-08-27 | `3540330c-e2d3-4d6b-89ca-02c198ac32e0` | `08:35:15`〜`09:50:02+00` | `9d90fd08-f9f1-4a4e-8910-38ec391e590e` |

**注意:** 孤児は 14 日 backfill で **再出現済み**（例: 2026-09-07 02:50 前後）。keep id / garmin_activity_id は安定だが、**orphan id は変わりうる**。適用直前 dry-run で必ず再確認し、変わっていればマイグレーション内の明示 ID を更新する。

メトリクス差分（マージ時に孤児側を埋める候補）:

| 列 | Claude keep | orphan |
|---|---|---|
| `calories_burned` | 値あり（Claude/手動） | NULL（#28 省略の結果）→ **マージ時は触らず**、末尾 apply で Garmin 合計へ |
| `hr_zone_minutes` | NULL | あり |
| `elevation_gain_m` | NULL | あり |
| `metadata` | `{}` | Connect / bundle 等 |

### 再出現リスク

- 孤児を削除しても、cleanup 前に Claude 行が NULL キーのままなら **14 日 backfill で孤児が再 INSERT**される
- cleanup で keep にフルキーを埋めた後は、同一論理キー upsert で 1 行に収束する（UNIQUE 衝突）
- **CHECK 適用前**に Claude が再び論理キー欠落 INSERT すると同型バグが再発 → Phase 0 を cleanup / CHECK より先に運用開始すること

### 現行スキーマ（本番確認済み・衝突しないこと）

| 制約 / API | 内容 |
|---|---|
| `training_log_logical_unique` | `UNIQUE (user_id, start_time, end_time, workout_type)` |
| `training_log_healthkit_uuid_key` | `UNIQUE (healthkit_uuid)`（NULL 可・複数 NULL 可） |
| `link_garmin_activity_training_log(p_user_id uuid)` | `service_role`、±120s、`training_log_id IS NULL` のみ（**本 Issue で変更しない**） |
| `apply_garmin_calories_to_training_log(p_user_id uuid)` | `service_role`、リンク済み garmin のみ |
| iOS conflict | `"user_id,start_time,end_time,workout_type"`（変更しない） |
| `TrainingLogRecord` | 注釈列を encode しない（PostgREST が注釈を潰さない） |

---

## 4. 実装ステップ（ファイルパス + マイグレーション命名）

### 命名規約（リポジトリ準拠）

`supabase/migrations/YYYYMMDDHHMMSS_snake_case_description.sql`

ローカル最新例: `20260821140000_drop_training_log_avg_max_hr.sql`  
本番適用名はタイムスタンプがずれることがあるが、**リポジトリ側は日付+意味のある snake_case** を続ける。

本 Issue 推奨ファイル名:

| 順序 | ファイル | 内容 |
|---|---|---|
| 1 | `supabase/migrations/20260907120000_merge_null_key_training_log_duplicates.sql` | Phase 1 cleanup（明示 ID・冪等・末尾 apply） |
| 2 | `supabase/migrations/20260907130000_training_log_garmin_times_check_and_annotation_rpc.sql` | Phase 2 CHECK + map helper + annotation RPC |

iOS / Python ジョブ / `link_garmin_*` の **コード変更は無し**。

### Phase 0 — 即時 ops（コードなし・先に実行）

**目的:** CHECK 前でも再発を止める。

運用ルール（Claude / 人間オペ）:

1. `data_source='garmin'` で次が欠落した **INSERT 禁止:**  
   **`start_time` / `end_time` / `workout_type`**（および `data_source` 自体の誤設定）  
   - **`healthkit_uuid` は必須にしない。** archive 先行 INSERT や RPC フルキー INSERT では NULL のまま許可し、**後続 HK upsert が同一論理キーで埋める**（#12 と整合）
2. RPE / `condition_notes` 等は既存 `training_log` を検索して **PATCH（注釈列のみ）**
3. 行が無い場合:
   - archive から **フル論理キー（times + workout_type）付き**で INSERTするか（uuid は後埋め可）
   - HK 同期待ち（推奨: まず sync → 行ができてから PATCH）
4. 暫定の重複掃除は「RPE 空の孤児削除」ではなく、**正規行へキー埋め → 孤児削除**（スキップだけだと NULL キーが永久に残る）

実装物: PR1 の docs。最低限 Issue / チャット運用で周知。

### Phase 1 — cleanup マイグレーション

ファイル: `supabase/migrations/20260907120000_merge_null_key_training_log_duplicates.sql`

方針（ロック）:

- **生存させたい行** = `garmin_activity_archive.training_log_id` が指す Claude id
- orphan から `start_time` / `end_time` / `healthkit_uuid` を backfill
- HK 由来で keep が空のメトリクス（`hr_zone_minutes` / `elevation_gain_m` / `metadata` 等）は COALESCE
- **`calories_burned` は keep を手で潰さない**（orphan 由来で上書きしない）
- orphan DELETE
- archive.`training_log_id` は変更不要（既に keep）
- **末尾:** keep の `user_id` に対し `apply_garmin_calories_to_training_log(p_user_id)` を呼び Garmin 合計へ揃える（#28）
- **冪等:** orphan 欠落時は archive からキーのみ埋める / keep が既にフルキーなら no-op（§7.2）

詳細 SQL は §7。

### Phase 2 — CHECK + map helper + annotation RPC（PR3）

ファイル: `supabase/migrations/20260907130000_training_log_garmin_times_check_and_annotation_rpc.sql`

1. `ADD CONSTRAINT ... CHECK (...) NOT VALID`
2. map helper: `garmin_activity_type_to_workout_type(text)` / `garmin_activity_type_to_discipline(text)`（§5.2）  
   - 各関数: `REVOKE ALL ... FROM PUBLIC` → `GRANT EXECUTE ... TO authenticated, service_role`
3. `CREATE OR REPLACE FUNCTION upsert_training_log_annotation(...)`（§5.5 スケルトン）  
   - 同様に `REVOKE` / `GRANT EXECUTE` to `authenticated` + `service_role`
4. cleanup 成功後に `VALIDATE CONSTRAINT`
5. docs に RPC 例を追記（PR3 または PR1 への追コミット）

**含めない:** `link_garmin_activity_training_log` の変更（後回し・Appendix C）。`p_date` 引数なし。

**適用順の硬制約:** Phase 1 マイグレーションが先。`VALIDATE` は NULL キー 0 件が前提。

### Phase 3 — docs（PR1 で先行、RPC 例は PR3）

ファイル: `docs/claude-garmin-access.md`

追加セクション案: **「主観データ（RPE 等）の書き方」**（§9）

任意追随: `README.md` に 1 行。`docs/garmin-sync-ops.md` は変更不要。

### 変更しないファイル（明示）

| ファイル | 理由 |
|---|---|
| `MyVitalRelay/Sync/SyncEngine.swift` | onConflict / #12 削除保護 / 14 日 backfill 維持 |
| `MyVitalRelay/Sync/TrainingLogRecord.swift` | 注釈非 encode 維持 |
| `MyVitalRelay/Mapping/WorkoutMapper.swift` | #28 calories 省略・論理キー生成維持 |
| `MyVitalRelay/HealthKit/WorkoutSnapshot.swift` | `displayName` が workout_type 正 |
| `scripts/garmin_sync_job.py` / `garmin_sync_lib.py` | archive + link + apply のみ。CREATE 追加禁止 |
| `link_garmin_activity_training_log` | 本 Issue スコープ外（後回し） |
| `supabase/migrations/20260709100000_training_log_logical_unique.sql` | 既存 UNIQUE を変更しない |

---

## 5. RPC シグネチャ・解決順・実装スケルトン

### 5.1 目的

Claude の書き込み口を **注釈中心**に一本化し、やむを得ない新規行は **archive 由来のフルキー INSERT** のみ許可する。

### 5.2 map helper（PR3 マイグレーション先頭で定義）

```sql
CREATE OR REPLACE FUNCTION garmin_activity_type_to_workout_type(p_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_key
    WHEN 'running' THEN 'Running'
    WHEN 'treadmill_running' THEN 'Running'
    WHEN 'walking' THEN 'Walking'
    WHEN 'stair_climbing' THEN 'StairClimbing'
    WHEN 'strength_training' THEN 'TraditionalStrengthTraining'
    WHEN 'virtual_ride' THEN 'Cycling'
    WHEN 'cycling' THEN 'Cycling'
    WHEN 'road_biking' THEN 'Cycling'
    WHEN 'indoor_cycling' THEN 'Cycling'
    WHEN 'swimming' THEN 'Swimming'
    WHEN 'lap_swimming' THEN 'Swimming'
    WHEN 'open_water_swimming' THEN 'Swimming'
    WHEN 'hiking' THEN 'Hiking'
    WHEN 'elliptical' THEN 'Elliptical'
    WHEN 'rowing' THEN 'Rowing'
    WHEN 'indoor_rowing' THEN 'Rowing'
    WHEN 'yoga' THEN 'Yoga'
    WHEN 'floor_climbing' THEN 'Other(3000)'  -- 本番リンク実測の正
    ELSE NULL  -- 未知 → 呼び出し側で例外
  END;
$$;

CREATE OR REPLACE FUNCTION garmin_activity_type_to_discipline(p_key text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE garmin_activity_type_to_workout_type(p_key)
    WHEN 'Running' THEN 'run'
    WHEN 'Walking' THEN 'run'
    WHEN 'Cycling' THEN 'bike'
    WHEN 'Swimming' THEN 'swim'
    WHEN 'TraditionalStrengthTraining' THEN 'strength'
    WHEN 'FunctionalStrengthTraining' THEN 'strength'
    WHEN NULL THEN NULL
    ELSE 'other'
  END;
$$;

REVOKE ALL ON FUNCTION garmin_activity_type_to_workout_type(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION garmin_activity_type_to_discipline(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION garmin_activity_type_to_workout_type(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION garmin_activity_type_to_discipline(text) TO authenticated, service_role;
```

### 5.3 シグネチャ（確定・`p_date` なし）

解決に使えるのは **`p_training_log_id`** と **`p_garmin_activity_id`** のみ。

```sql
CREATE OR REPLACE FUNCTION upsert_training_log_annotation(
  p_training_log_id uuid DEFAULT NULL,
  p_garmin_activity_id bigint DEFAULT NULL,
  p_rpe smallint DEFAULT NULL,
  p_condition_notes text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_surface text DEFAULT NULL,
  p_equipment text DEFAULT NULL,
  p_allow_insert_from_archive boolean DEFAULT true
) RETURNS uuid  -- 対象 training_log.id
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$ /* 本体は §5.5 */ $$;

REVOKE ALL ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) TO authenticated;
GRANT EXECUTE ON FUNCTION upsert_training_log_annotation(
  uuid, bigint, smallint, text, text, text, text, boolean
) TO service_role;
```

実装規約（ロック）:

- `auth.uid()` と対象行 / archive の `user_id` が一致することを強制
- **部分更新:** 引数が **NULL ならその列を触らない**
- `rpe` は既存 CHECK `BETWEEN 1 AND 10` に従う
- INSERT 時は `data_source='garmin'` + **必ず** `start_time`/`end_time`/`workout_type`
- INSERT 時の `calories_burned` / `healthkit_uuid` は **NULL 可**

### 5.4 解決順（ロック）

```
1. p_training_log_id が非 NULL
     → その id の行（user_id = auth.uid()）を対象。無ければ例外。

2. p_garmin_activity_id が非 NULL
     → archive を auth.uid() + garmin_activity_id で特定。無ければ例外。
     a. archive.training_log_id あり → その行（所有者チェック）
     b. 無し → ±120s + duration≤120s + workout_type=map(key) で既存フルキー行を探す
        → 見つかれば対象 + archive.training_log_id を更新
     c. 未解決かつ p_allow_insert_from_archive
        → map(key) が NULL なら例外（未知 typeKey）
        → archive からフルキー INSERT（uuid/calories NULL）+ archive リンク
     d. allow_insert=false で未解決 → 例外

3. p_training_log_id も p_garmin_activity_id も NULL
     → 例外（「training_log_id または garmin_activity_id を指定」）

4. 対象行に対し注釈の部分 UPDATE → RETURN id
```

**禁止:** `p_date` による探索。NULL キー INSERT。未知 typeKey の INSERT。

### 5.5 実装可能な plpgsql スケルトン

完全プロダクション品質でなくてよいが、分岐・権限・部分 UPDATE・INSERT・例外・map 呼び出しが追えること。

```sql
CREATE OR REPLACE FUNCTION upsert_training_log_annotation(
  p_training_log_id uuid DEFAULT NULL,
  p_garmin_activity_id bigint DEFAULT NULL,
  p_rpe smallint DEFAULT NULL,
  p_condition_notes text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_surface text DEFAULT NULL,
  p_equipment text DEFAULT NULL,
  p_allow_insert_from_archive boolean DEFAULT true
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_target_id uuid;
  v_arch garmin_activity_archive%ROWTYPE;
  v_workout_type text;
  v_discipline text;
  v_start timestamptz;
  v_end timestamptz;
  v_date date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'upsert_training_log_annotation: not authenticated';
  END IF;

  IF p_training_log_id IS NULL AND p_garmin_activity_id IS NULL THEN
    RAISE EXCEPTION
      'upsert_training_log_annotation: provide p_training_log_id or p_garmin_activity_id';
  END IF;

  -- 1) 明示 id
  IF p_training_log_id IS NOT NULL THEN
    SELECT t.id INTO v_target_id
    FROM training_log t
    WHERE t.id = p_training_log_id
      AND t.user_id = v_uid;
    IF v_target_id IS NULL THEN
      RAISE EXCEPTION
        'upsert_training_log_annotation: training_log % not found for user',
        p_training_log_id;
    END IF;

  -- 2) garmin_activity_id
  ELSE
    SELECT a.* INTO v_arch
    FROM garmin_activity_archive a
    WHERE a.user_id = v_uid
      AND a.garmin_activity_id = p_garmin_activity_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'upsert_training_log_annotation: garmin_activity_id % not found',
        p_garmin_activity_id;
    END IF;

    v_workout_type := garmin_activity_type_to_workout_type(v_arch.activity_type_key);
    v_discipline := garmin_activity_type_to_discipline(v_arch.activity_type_key);

    IF v_arch.training_log_id IS NOT NULL THEN
      SELECT t.id INTO v_target_id
      FROM training_log t
      WHERE t.id = v_arch.training_log_id
        AND t.user_id = v_uid;
      IF v_target_id IS NULL THEN
        RAISE EXCEPTION
          'upsert_training_log_annotation: linked training_log % missing',
          v_arch.training_log_id;
      END IF;

    ELSE
      -- ±120s + duration + workout_type マッチ
      IF v_workout_type IS NOT NULL THEN
        SELECT t.id INTO v_target_id
        FROM training_log t
        WHERE t.user_id = v_uid
          AND t.data_source = 'garmin'
          AND t.start_time IS NOT NULL
          AND v_arch.start_time_local IS NOT NULL
          AND t.start_time BETWEEN v_arch.start_time_local - interval '120 seconds'
                               AND v_arch.start_time_local + interval '120 seconds'
          AND (
            v_arch.duration_sec IS NULL
            OR t.duration_min IS NULL
            OR abs(t.duration_min * 60 - v_arch.duration_sec) <= 120
          )
          AND t.workout_type = v_workout_type
        ORDER BY abs(extract(epoch FROM (t.start_time - v_arch.start_time_local)))
        LIMIT 1;

        IF v_target_id IS NOT NULL THEN
          UPDATE garmin_activity_archive
          SET training_log_id = v_target_id
          WHERE id = v_arch.id
            AND training_log_id IS NULL;
        END IF;
      END IF;

      -- フルキー INSERT
      IF v_target_id IS NULL THEN
        IF NOT p_allow_insert_from_archive THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: no training_log for activity % (insert disabled)',
            p_garmin_activity_id;
        END IF;
        IF v_workout_type IS NULL OR v_discipline IS NULL THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: unknown activity_type_key %',
            v_arch.activity_type_key;
        END IF;
        IF v_arch.start_time_local IS NULL OR v_arch.duration_sec IS NULL THEN
          RAISE EXCEPTION
            'upsert_training_log_annotation: archive % missing start/duration',
            p_garmin_activity_id;
        END IF;

        v_start := v_arch.start_time_local;
        v_end := v_arch.start_time_local
          + make_interval(secs => v_arch.duration_sec::double precision);
        v_date := (v_start AT TIME ZONE 'Asia/Tokyo')::date;

        INSERT INTO training_log (
          user_id, date, data_source,
          healthkit_uuid, discipline, workout_type,
          start_time, end_time, duration_min,
          calories_burned,
          rpe, condition_notes, notes, surface, equipment,
          updated_at
        ) VALUES (
          v_uid, v_date, 'garmin',
          NULL, v_discipline, v_workout_type,
          v_start, v_end, v_arch.duration_sec / 60.0,
          NULL,
          p_rpe, p_condition_notes, p_notes, p_surface, p_equipment,
          now()
        )
        RETURNING id INTO v_target_id;

        UPDATE garmin_activity_archive
        SET training_log_id = v_target_id
        WHERE id = v_arch.id;

        RETURN v_target_id;  -- INSERT 時は VALUES で注釈済み
      END IF;
    END IF;
  END IF;

  -- 部分 UPDATE（引数 NULL の列は触らない）
  UPDATE training_log t
  SET
    rpe = CASE WHEN p_rpe IS NOT NULL THEN p_rpe ELSE t.rpe END,
    condition_notes = CASE
      WHEN p_condition_notes IS NOT NULL THEN p_condition_notes ELSE t.condition_notes END,
    notes = CASE WHEN p_notes IS NOT NULL THEN p_notes ELSE t.notes END,
    surface = CASE WHEN p_surface IS NOT NULL THEN p_surface ELSE t.surface END,
    equipment = CASE WHEN p_equipment IS NOT NULL THEN p_equipment ELSE t.equipment END,
    updated_at = now()
  WHERE t.id = v_target_id
    AND t.user_id = v_uid;

  RETURN v_target_id;
END;
$$;
```

### 5.6 PostgREST 呼び出し例

```http
POST /rest/v1/rpc/upsert_training_log_annotation
Content-Type: application/json
Authorization: Bearer <user_access_token>

{
  "p_garmin_activity_id": 24108978987,
  "p_rpe": 3,
  "p_condition_notes": "暑さでペース抑制"
}
```

```http
POST /rest/v1/rpc/upsert_training_log_annotation
Content-Type: application/json

{
  "p_training_log_id": "5fa5ea06-6e10-438b-b990-8d31fc631eb1",
  "p_rpe": 2
}
```

未指定の注釈引数は省略 / `null` → **列は変更されない**。

---

## 6. Garmin `activity_type_key` → HK `workout_type` 対応表

### 正の定義（コード）

`workout_type` の正は iOS `HKWorkoutActivityType.displayName`（`MyVitalRelay/HealthKit/WorkoutSnapshot.swift`）。

| HK case | `displayName`（DB に入る値） |
|---|---|
| `.running` | `Running` |
| `.walking` | `Walking` |
| `.cycling` | `Cycling` |
| `.swimming` | `Swimming` |
| `.traditionalStrengthTraining` | `TraditionalStrengthTraining` |
| `.functionalStrengthTraining` | `FunctionalStrengthTraining` |
| `.hiking` | `Hiking` |
| `.elliptical` | `Elliptical` |
| `.rowing` | `Rowing` |
| `.stairClimbing` | `StairClimbing` |
| `.highIntensityIntervalTraining` | `HIIT` |
| `.crossTraining` | `CrossTraining` |
| `.yoga` | `Yoga` |
| `.coreTraining` | `CoreTraining` |
| default | `Other(<rawValue>)` |

`discipline` は `WorkoutMapper.discipline(for:)`:

| workout 系 | discipline |
|---|---|
| Running / Walking | `run` |
| Cycling | `bike` |
| Swimming | `swim` |
| TraditionalStrengthTraining / FunctionalStrengthTraining | `strength` |
| その他 | `other` |

### 本番 archive で確認済みの対応（リンク済み実測）

| `activity_type_key` | 件数 | リンク先 `workout_type`（実測） | RPC マップ |
|---|---|---|---|
| `running` | 23 | `Running` | `Running` / `run` |
| `treadmill_running` | 20 | `Running` | `Running` / `run` |
| `walking` | 20 | `Walking` | `Walking` / `run` |
| `stair_climbing` | 19 | `StairClimbing` | `StairClimbing` / `other` |
| `strength_training` | 4 | `TraditionalStrengthTraining` | `TraditionalStrengthTraining` / `strength` |
| `virtual_ride` | 1 | `Cycling` | `Cycling` / `bike` |
| `floor_climbing` | 1 | `Other(3000)` | **`Other(3000)` / `other`（既知キーとして固定）** |

`floor_climbing` → `Other(3000)` は **本プロジェクト本番リンク実測の正**としてマップに固定する。`Other(<rawValue>)` は OS / HK バージョンで rawValue が変わりうるが、未知キー拒否方針とは矛盾しない（**既知エントリとして明示**し、推測フォールバックはしない）。将来 raw がずれて HK と論理キー不一致になったら、実測を見てマップを更新する。

### まだ本番未出現だがマップに含める候補

| `activity_type_key`（Garmin 慣例） | 推奨 `workout_type` | discipline |
|---|---|---|
| `cycling` / `road_biking` / `indoor_cycling` | `Cycling` | `bike` |
| `swimming` / `lap_swimming` / `open_water_swimming` | `Swimming` | `swim` |
| `hiking` | `Hiking` | `other` |
| `elliptical` | `Elliptical` | `other` |
| `rowing` / `indoor_rowing` | `Rowing` | `other` |
| `yoga` | `Yoga` | `other` |

**未知キー:** `CASE` に無い `activity_type_key` は **INSERT 拒否（例外）**。マップ表を更新してから再実行。

---

## 7. Cleanup SQL アプローチ

### 7.1 Dry-run（適用直前に必須・結果を保存）

```sql
-- A. NULL キー garmin 行
SELECT id, user_id, date, workout_type, rpe,
       condition_notes IS NOT NULL AS has_notes,
       start_time, end_time, healthkit_uuid, created_at
FROM training_log
WHERE data_source = 'garmin'
  AND (start_time IS NULL OR end_time IS NULL)
ORDER BY date;

-- B. archive が指す keep と、±120s のフルキー孤児
SELECT
  a.garmin_activity_id,
  a.training_log_id AS keep_id,
  a.start_time_local,
  a.duration_sec,
  o.id AS orphan_id,
  o.start_time,
  o.end_time,
  o.healthkit_uuid,
  o.rpe AS orphan_rpe,
  k.rpe AS keep_rpe,
  k.start_time IS NULL AS keep_still_null_key
FROM garmin_activity_archive a
JOIN training_log k ON k.id = a.training_log_id
LEFT JOIN training_log o
  ON o.user_id = a.user_id
 AND o.data_source = 'garmin'
 AND o.start_time IS NOT NULL
 AND o.id <> k.id
 AND o.start_time BETWEEN a.start_time_local - interval '120 seconds'
                      AND a.start_time_local + interval '120 seconds'
 AND o.workout_type = k.workout_type
WHERE a.garmin_activity_id IN (24108978987, 24133970032)
ORDER BY a.start_time_local;

-- C. 期待ペア（2026-09-07 計画時点・変わりうるのは orphan id）
-- keep 5fa5ea06-6e10-438b-b990-8d31fc631eb1 ↔ orphan 0b5c9517-7236-42fe-bbf1-48a4c5aae613
-- keep 42c84798-81a3-4f73-9caa-868f59cc7b3d ↔ orphan 3540330c-e2d3-4d6b-89ca-02c198ac32e0
```

**強調:** 孤児は backfill で再 INSERT され **id が変わりうる**（2026-09-07 02:50 再出現実績あり）。dry-run の `orphan_id` が計画と違う場合は、マイグレーション内の明示 UUID を更新してから APPLY。keep id と `garmin_activity_id` は archive リンク基準で安定。

### 7.2 APPLY（完全スケッチ・両ペア・冪等）

ファイル本体の実装可能スケッチ。単一トランザクション。順序は **保存 → UNIQUE 解放 → keep backfill → orphan DELETE →（ペア2）→ apply**。

```sql
-- Issue #33 Phase 1
-- Merge NULL-key Claude rows with HK orphan full-key rows.
-- Idempotent: orphan missing → fill keys from archive if keep still NULL-keyed; else no-op.
-- calories_burned: do not overwrite keep from orphan; align via apply_* at end (#28).

BEGIN;

DO $$
DECLARE
  -- Pair 1: 2026-08-25（orphan id は適用直前 dry-run で要確認）
  v_keep_id uuid := '5fa5ea06-6e10-438b-b990-8d31fc631eb1';
  v_orphan_id uuid := '0b5c9517-7236-42fe-bbf1-48a4c5aae613';
  v_garmin_activity_id bigint := 24108978987;

  v_start timestamptz;
  v_end timestamptz;
  v_hk uuid;
  v_duration_min numeric;
  v_distance_km numeric;
  v_avg_speed_kmh numeric;
  v_hr_zone jsonb;
  v_elev numeric;
  v_stroke numeric;
  v_metadata jsonb;
  v_arch_start timestamptz;
  v_arch_duration numeric;
BEGIN
  -- 1) orphan がいる: 値を先に保存（解放前）
  SELECT
    o.start_time, o.end_time, o.healthkit_uuid,
    o.duration_min, o.distance_km, o.avg_speed_kmh,
    o.hr_zone_minutes, o.elevation_gain_m, o.stroke_count, o.metadata
  INTO
    v_start, v_end, v_hk,
    v_duration_min, v_distance_km, v_avg_speed_kmh,
    v_hr_zone, v_elev, v_stroke, v_metadata
  FROM training_log o
  WHERE o.id = v_orphan_id;

  IF FOUND THEN
    -- 2) UNIQUE スロット解放
    UPDATE training_log
    SET healthkit_uuid = NULL,
        start_time = NULL,
        end_time = NULL,
        updated_at = now()
    WHERE id = v_orphan_id;

    -- 3) keep backfill（calories_burned は触らない）
    UPDATE training_log k
    SET
      start_time = v_start,
      end_time = v_end,
      healthkit_uuid = v_hk,
      duration_min = COALESCE(k.duration_min, v_duration_min),
      distance_km = COALESCE(k.distance_km, v_distance_km),
      avg_speed_kmh = COALESCE(k.avg_speed_kmh, v_avg_speed_kmh),
      hr_zone_minutes = COALESCE(k.hr_zone_minutes, v_hr_zone),
      elevation_gain_m = COALESCE(k.elevation_gain_m, v_elev),
      stroke_count = COALESCE(k.stroke_count, v_stroke),
      metadata = CASE
        WHEN k.metadata IS NULL OR k.metadata = '{}'::jsonb THEN COALESCE(v_metadata, '{}'::jsonb)
        ELSE k.metadata
      END,
      updated_at = now()
    WHERE k.id = v_keep_id;

    -- 4) orphan DELETE
    DELETE FROM training_log WHERE id = v_orphan_id;
  ELSE
    -- 冪等: orphan 無し
    -- keep がまだ NULL キー → archive から times のみ埋める（uuid は無いので NULL のまま可）
    SELECT a.start_time_local, a.duration_sec
    INTO v_arch_start, v_arch_duration
    FROM garmin_activity_archive a
    WHERE a.garmin_activity_id = v_garmin_activity_id
      AND a.training_log_id = v_keep_id;

    IF FOUND THEN
      UPDATE training_log k
      SET
        start_time = COALESCE(k.start_time, v_arch_start),
        end_time = COALESCE(
          k.end_time,
          v_arch_start + make_interval(secs => v_arch_duration::double precision)
        ),
        duration_min = COALESCE(k.duration_min, v_arch_duration / 60.0),
        updated_at = now()
      WHERE k.id = v_keep_id
        AND (k.start_time IS NULL OR k.end_time IS NULL);
      -- keep が既にフルキーなら WHERE 不一致 → no-op
    END IF;
  END IF;
END $$;

DO $$
DECLARE
  -- Pair 2: 2026-08-27（orphan id は適用直前 dry-run で要確認）
  v_keep_id uuid := '42c84798-81a3-4f73-9caa-868f59cc7b3d';
  v_orphan_id uuid := '3540330c-e2d3-4d6b-89ca-02c198ac32e0';
  v_garmin_activity_id bigint := 24133970032;

  v_start timestamptz;
  v_end timestamptz;
  v_hk uuid;
  v_duration_min numeric;
  v_distance_km numeric;
  v_avg_speed_kmh numeric;
  v_hr_zone jsonb;
  v_elev numeric;
  v_stroke numeric;
  v_metadata jsonb;
  v_arch_start timestamptz;
  v_arch_duration numeric;
BEGIN
  SELECT
    o.start_time, o.end_time, o.healthkit_uuid,
    o.duration_min, o.distance_km, o.avg_speed_kmh,
    o.hr_zone_minutes, o.elevation_gain_m, o.stroke_count, o.metadata
  INTO
    v_start, v_end, v_hk,
    v_duration_min, v_distance_km, v_avg_speed_kmh,
    v_hr_zone, v_elev, v_stroke, v_metadata
  FROM training_log o
  WHERE o.id = v_orphan_id;

  IF FOUND THEN
    UPDATE training_log
    SET healthkit_uuid = NULL,
        start_time = NULL,
        end_time = NULL,
        updated_at = now()
    WHERE id = v_orphan_id;

    UPDATE training_log k
    SET
      start_time = v_start,
      end_time = v_end,
      healthkit_uuid = v_hk,
      duration_min = COALESCE(k.duration_min, v_duration_min),
      distance_km = COALESCE(k.distance_km, v_distance_km),
      avg_speed_kmh = COALESCE(k.avg_speed_kmh, v_avg_speed_kmh),
      hr_zone_minutes = COALESCE(k.hr_zone_minutes, v_hr_zone),
      elevation_gain_m = COALESCE(k.elevation_gain_m, v_elev),
      stroke_count = COALESCE(k.stroke_count, v_stroke),
      metadata = CASE
        WHEN k.metadata IS NULL OR k.metadata = '{}'::jsonb THEN COALESCE(v_metadata, '{}'::jsonb)
        ELSE k.metadata
      END,
      updated_at = now()
    WHERE k.id = v_keep_id;

    DELETE FROM training_log WHERE id = v_orphan_id;
  ELSE
    SELECT a.start_time_local, a.duration_sec
    INTO v_arch_start, v_arch_duration
    FROM garmin_activity_archive a
    WHERE a.garmin_activity_id = v_garmin_activity_id
      AND a.training_log_id = v_keep_id;

    IF FOUND THEN
      UPDATE training_log k
      SET
        start_time = COALESCE(k.start_time, v_arch_start),
        end_time = COALESCE(
          k.end_time,
          v_arch_start + make_interval(secs => v_arch_duration::double precision)
        ),
        duration_min = COALESCE(k.duration_min, v_arch_duration / 60.0),
        updated_at = now()
      WHERE k.id = v_keep_id
        AND (k.start_time IS NULL OR k.end_time IS NULL);
    END IF;
  END IF;
END $$;

-- 5) #28: keep を手で潰さず、リンク済み行を Garmin 合計へ揃える
-- user_id 本番確認済み（2026-09-07）: 77ea5bd6-e655-4f45-8143-40777562ace1
SELECT apply_garmin_calories_to_training_log(
  '77ea5bd6-e655-4f45-8143-40777562ace1'::uuid
);

COMMIT;
```

冪等性まとめ:

| 状態 | 動作 |
|---|---|
| orphan あり・keep NULL キー | 保存 → 解放 → keep にフルキー+メトリクス → orphan DELETE |
| orphan 無し・keep NULL キー | archive(`24108978987` / `24133970032`) の `start_time_local` + `duration_sec` で times 埋め |
| orphan 無し・keep フルキー | no-op（UPDATE 0 行） |
| 2 回適用 | 2 回目は orphan 無し + keep フルキー → no-op。apply は `IS DISTINCT FROM` で差分のみ |

### 7.3 適用後検証

```sql
SELECT count(*) AS null_key_garmin
FROM training_log
WHERE data_source = 'garmin'
  AND (start_time IS NULL OR end_time IS NULL);
-- expect 0

SELECT id, date, rpe, start_time IS NOT NULL AS has_start, healthkit_uuid, calories_burned
FROM training_log
WHERE id IN (
  '5fa5ea06-6e10-438b-b990-8d31fc631eb1',
  '42c84798-81a3-4f73-9caa-868f59cc7b3d'
);
-- expect rpe 2 / 4, has_start true
-- calories_burned ≈ archive summaryDTO.calories（apply 後）

SELECT a.garmin_activity_id, a.training_log_id, t.start_time, t.rpe, t.calories_burned
FROM garmin_activity_archive a
JOIN training_log t ON t.id = a.training_log_id
WHERE a.garmin_activity_id IN (24108978987, 24133970032);
```

---

## 8. CHECK 制約（NOT VALID → VALIDATE）

```sql
ALTER TABLE training_log
  ADD CONSTRAINT training_log_garmin_requires_times_check
  CHECK (
    data_source <> 'garmin'
    OR (start_time IS NOT NULL AND end_time IS NOT NULL)
  ) NOT VALID;

-- Phase 1 成功・null_key_garmin = 0 を確認後:
ALTER TABLE training_log
  VALIDATE CONSTRAINT training_log_garmin_requires_times_check;
```

| ポイント | 内容 |
|---|---|
| `NOT VALID` | 既存行をスキャンせず追加。**新規/更新**には即効く |
| `VALIDATE` | 既存行を検査。NULL キーが残ると失敗 → cleanup 必須 |
| `manual` | `data_source <> 'garmin'` 分岐で時刻 NULL 継続可 |
| `life_fitness` | 通常 HK 経由で時刻あり。制約対象外（garmin のみ） |
| `workout_type` | 本 CHECK には含めない。RPC INSERT では必須 |
| `healthkit_uuid` | CHECK 対象外（NULL 可・HK 後埋め） |

ロールバック: `ALTER TABLE training_log DROP CONSTRAINT training_log_garmin_requires_times_check;`

---

## 9. Docs 変更アウトライン

対象: `docs/claude-garmin-access.md`

### 追加セクション（案タイトル）

`## X. 主観データ（RPE / condition_notes）の書き方`（Issue #33）

含める内容:

1. **禁止:** `start_time` / `end_time` / `workout_type` 欠落の garmin INSERT  
   （`healthkit_uuid` 欠落だけの INSERT は、フル論理キー付きなら可）
2. **推奨手順:**
   - `training_log` を date / discipline / start_time で検索
   - 既存行へ注釈列のみ PATCH  
     または `POST /rest/v1/rpc/upsert_training_log_annotation`（§5.6）
3. **行が無いとき:** HK 同期待ち、または `garmin_activity_id` / `training_log_id` 付き RPC（archive フルキー INSERT、uuid は後埋め）。**date 単独では解決しない**
4. **部分更新:** RPC 引数を省略 / null → その列は変更されない（クリア不可）
5. **やってはいけないこと:** 重複行を作って後から orphan 削除する運用の常態化
6. **よくある誤解表に追記:**
   - 「RPE 用に先に空行を作る」→ NULL キー穴になる
   - 「archive に training_log_id があれば HK は挿入しない」→ **誤り**
   - 「distance_km が違うから別セッション」→ 丸め差の可能性。論理キーを見る
   - 「healthkit_uuid が無いと INSERT できない」→ **誤り**（times + workout_type が必須）

既存 §1（#28）・§4 からは本セクションへリンク。

PR1: PATCH / 禁止事項を先行。PR3 後: RPC 例を追記。

---

## 10. テスト計画

### 10.1 SQL / DB

| # | ケース | 期待 |
|---|---|---|
| S1 | cleanup 後 `null_key_garmin` | 0 |
| S2 | keep 2 行の RPE / notes | 非 NULL のまま |
| S3 | archive 2 activity の `training_log_id` | keep id、`start_time` 非 NULL |
| S4 | `INSERT ... data_source='garmin', start_time=NULL` | CHECK 違反 |
| S5 | `INSERT ... data_source='manual', start_time=NULL` | 成功 |
| S6 | RPC: 既存 id に RPE | 注釈のみ更新。論理キー不変。他注釈列不変 |
| S7 | RPC: garmin_activity_id（未リンク・HK 行あり） | 既存フルキー行に注釈 + archive link |
| S8 | RPC: garmin_activity_id（行なし） | フルキー INSERT（uuid NULL 可）+ archive link |
| S9 | RPC: 未知 activity_type_key で INSERT 経路 | 例外 |
| S10 | RPC: 両方の id 引数 NULL / 権限外 | 失敗 |
| S10b | RPC: `p_date` なし（シグネチャに存在しない） | N/A（解決経路に date 探索なし） |
| S11 | VALIDATE CONSTRAINT | 成功 |
| S12 | **冪等 cleanup:** orphan 無し・keep NULL キー | archive から times 埋め。RPE 保持 |
| S13 | **冪等 cleanup:** orphan 無し・keep フルキー | no-op（キー・注釈不変） |
| S14 | **冪等 cleanup:** 同一マイグレーション相当を 2 回適用 | 壊れない。null_key=0 維持 |
| S15 | cleanup 末尾 apply 後 | keep の `calories_burned` が Garmin 合計と一致（差分 UPDATE） |

### 10.2 ユニット（コード変更が無い場合は最小）

| # | 対象 | 内容 |
|---|---|---|
| U1 | map helper | `activity_type_key` → `workout_type`（既知表 + 未知は NULL/例外） |
| U2 | 既存 `WorkoutMapperTests` | **回帰:** 注釈列非 encode、#28 calories 省略、logical key |
| U3 | 既存 `tests/test_garmin_sync_lib.py` | link → apply 順・CREATE 無しの回帰 |

### 10.3 マニュアル

1. Phase 0 周知後、Claude で既存 garmin 行へ RPE PATCH → アプリ起動（14 日 backfill）→ **行が増えない**
2. cleanup + CHECK 後、意図的に NULL キー INSERT を試し **失敗**
3. RPC で archive 先行の日に RPE（uuid NULL）→ 後から HK sync → **1 行にマージ**され RPE 残存
4. Garmin UUID 差し替え（#12）: 注釈付き行が delete で消えない
5. 新規 garmin 同期後、calories が apply まで NULL→合計（#28）
6. `garmin_sync_job` が `training_log` を CREATE していない

---

## 11. ロールアウト / ロールバック

### 推奨順序

```
1. PR1: Phase 0 + docs（PATCH / 禁止。RPC は「PR3 後」注記可）
2. Dry-run SQL → orphan id 確定（変わっていたら PR2 SQL 更新）
3. PR2: マイグレーション 20260907120000（cleanup + apply）適用
4. 検証クエリ（§7.3）
5. PR3: マイグレーション 20260907130000
     - CHECK NOT VALID
     - map helper + upsert_training_log_annotation
     - VALIDATE CHECK
     - docs RPC 例
6. 監視: 週次で null_key_garmin = 0
```

アプリリリース依存は **無し**。

### ロールバック

| 段階 | 戻し方 |
|---|---|
| CHECK のみ | `DROP CONSTRAINT training_log_garmin_requires_times_check` |
| RPC / map helper | `DROP FUNCTION ...` |
| cleanup | **原則不可逆**（orphan DELETE）。適用前に dry-run 結果と削除 ID を Issue に残す |
| docs | git revert |

cleanup 前に `BEGIN; ...; ROLLBACK;` でリハーサル推奨。

### リスク

| リスク | 緩和 |
|---|---|
| cleanup 誤結合 | 明示 ID + dry-run。orphan id 再確認 |
| orphan id 変化 | 適用直前 dry-run。冪等の archive フォールバック |
| VALIDATE 失敗 | cleanup 再確認。NOT VALID のまま新規だけ防ぎ、修正後 VALIDATE |
| RPC 誤 INSERT（未知 type） | **拒否**。マップ更新運用 |
| Claude が直 INSERT | CHECK が砦。docs で RPC/PATCH 誘導 |
| calories 一時不一致 | 末尾 apply で Garmin 合計へ。keep 手潰しなし |
| 孤児再出現（cleanup 前） | Phase 0 先行。cleanup を急ぐ |

---

## 12. Acceptance criteria（Issue コメントより）

- [ ] 新規に `data_source='garmin'` かつ `start_time`/`end_time` NULL の行が INSERT できない
- [ ] Claude が既存 HK 行へ RPE PATCH 後、14 日 backfill 付き同期でも行が増えない
- [ ] フル論理キー付き Claude INSERT → 後続 HK upsert で 1 行にマージされ、RPE / `condition_notes` が残る
- [ ] 既存 NULL キー重複が消え、archive.`training_log_id` が生存行を指す
- [ ] Issue #12: UUID 差し替え・注釈保護削除が退行しない
- [ ] Issue #28: garmin upsert に `calories_burned` が無く、リンク後 RPC で合計が入る
- [ ] Garmin job が `training_log` を CREATE しない（回帰なし）
- [ ] `distance_km` 比較 dedup を導入していない
- [ ] docs に Claude の正しい書き込み手順がある

---

## 13. Effort / PR 分割（確定: 3 PR）

| PR | 内容 | 目安 | 依存 |
|---|---|---|---|
| **PR1** | Phase 0 + docs（必須キー= times + workout_type。PATCH。RPC は予定注記可） | XS | なし。**即マージ推奨** |
| **PR2** | Phase 1 cleanup マイグレーション（冪等 + 末尾 apply） | S | PR1 運用が走っていること。**適用直前 dry-run** |
| **PR3** | CHECK + map helper + `upsert_training_log_annotation` + docs RPC 例 | M | PR2 適用済み（VALIDATE 前提）。**`link_garmin` 変更なし** |

見積合計: **約 0.5〜1 日**。iOS 変更なし。

---

## 14. 実装チェックリスト（開発者向け）

- [ ] **適用直前 dry-run** で orphan id を再確認（変わっていれば SQL 更新）
- [ ] cleanup: 保存 → UNIQUE 解放 → keep backfill → DELETE → apply の順
- [ ] cleanup 冪等分岐（orphan 無し）を実装
- [ ] `calories_burned` を orphan から上書きしていない / 末尾 apply あり
- [ ] RPE / condition_notes が keep に残ることを検証
- [ ] CHECK は `NOT VALID` → 検証 → `VALIDATE`
- [ ] RPC: `auth.uid()` ガード、引数 NULL は列非更新、未知 typeKey は例外、**`p_date` なし**
- [ ] map helper / annotation RPC に `REVOKE` PUBLIC + `GRANT` authenticated / service_role
- [ ] archive INSERT は times + workout_type 必須、`healthkit_uuid` NULL 可
- [ ] `link_garmin_*` / SyncEngine / logical UNIQUE / 14 日 backfill を変更していない
- [ ] #12 削除フィルタを変更していない
- [ ] docs に禁止・PATCH・RPC・誤解表を書いた
- [ ] AC を Issue で全部閉じる

---

## 15. 親決定（ロック済み）

### 1 周目

| # | 項目 | 決定 |
|---|---|---|
| 1 | 注釈 NULL クリア API | **今イテレーションに含めない** |
| 2 | `link_garmin` マップ条件 | **完全に後回し**（Appendix C）。PR3 は CHECK + map helper + annotation RPC + docs のみ |
| 3 | 未知 `activity_type_key` | **INSERT 拒否** |
| 4 | cleanup 後 calories | 末尾で `apply_garmin_calories_to_training_log(p_user_id)` を **呼ぶ** |
| 5 | PR 分割 | **3 PR**（docs → cleanup → CHECK+RPC） |

### 2 周目（最終）

| # | 項目 | 決定 |
|---|---|---|
| 6 | RPC 解決キー | **`p_training_log_id` / `p_garmin_activity_id` のみ。`p_date` 削除** |
| 7 | RPC 本体 | §5.5 スケルトンを実装ベースとする |
| 8 | apply `user_id` | 確認済み `77ea5bd6-e655-4f45-8143-40777562ace1` |
| 9 | map helper 権限 | `REVOKE` PUBLIC + `GRANT` authenticated / service_role |

### 実装時確認のみ（設計未決ではない・これ以外に未決なし）

- [ ] **PR2 適用直前 dry-run で orphan id** が Appendix B と一致するか。不一致なら明示 UUID だけ更新して適用

**本計画は実装可能（親レビュー完了）。**
---

## Appendix A: 現状アーキテクチャ再確認メモ

| コンポーネント | 役割 | 本 Issue |
|---|---|---|
| `SyncEngine.syncWorkouts` | HK → logical upsert + 14d backfill + #12 delete | 変更なし |
| `WorkoutMapper` / `displayName` | workout_type / discipline / #28 calories | 変更なし（RPC マップの正本） |
| `link_garmin_activity_training_log` | archive → training_log ±120s | **変更なし（後回し）** |
| `apply_garmin_calories_to_training_log` | 合計 kcal 書き戻し | cleanup 末尾で呼ぶ。定義変更なし |
| Claude PostgREST | 現状テーブル直書き可能 | CHECK + docs + RPC で是正 |
| Garmin job | archive upsert のみ | CREATE 追加しない |

## Appendix B: 本番ペア ID 早見（2026-09-07）

| date | keep (Claude / archive 先) | orphan (HK・変わりうる) | garmin_activity_id |
|---|---|---|---|
| 2026-08-25 | `5fa5ea06-6e10-438b-b990-8d31fc631eb1` | `0b5c9517-7236-42fe-bbf1-48a4c5aae613` | `24108978987` |
| 2026-08-27 | `42c84798-81a3-4f73-9caa-868f59cc7b3d` | `3540330c-e2d3-4d6b-89ca-02c198ac32e0` | `24133970032` |

`user_id`（両 keep 共通）: `77ea5bd6-e655-4f45-8143-40777562ace1`

## Appendix C: 将来候補 — `link_garmin` マップ条件（スコープ外）

今イテレーションでは実装しない。将来やるなら:

- `workout_type = garmin_activity_type_to_workout_type(activity_type_key)` をマッチ条件に追加
- ジョブシグネチャ・GRANT は維持
- 既リンク付け替えは引き続き非推奨
