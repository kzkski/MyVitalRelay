import Foundation

enum HealthKitDeletionBatches {
    /// PostgREST の `in` はクエリ文字列に載る。
    /// 今朝の同期は sleep の削除 UUID 約726件で URL が 28KB になり、
    /// ゲートウェイが本文 `Bad Request` の 400 を返した（ヘッダ込みで受付上限を超える）。
    /// UUID 100件ならエンコード後およそ 4KB に収まる。
    static let uuidBatchSize = 100

    static func batches(of uuids: [UUID], size: Int = uuidBatchSize) -> [[UUID]] {
        guard size > 0 else { return uuids.isEmpty ? [] : [uuids] }
        var result: [[UUID]] = []
        result.reserveCapacity((uuids.count + size - 1) / size)
        var index = 0
        while index < uuids.count {
            let end = min(index + size, uuids.count)
            result.append(Array(uuids[index..<end]))
            index = end
        }
        return result
    }
}
