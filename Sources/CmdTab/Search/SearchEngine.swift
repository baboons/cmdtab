import CCmdTabCore
import Foundation

/// A ranked search result with highlight ranges (UTF-16, ready for NSRange).
struct SearchResult {
    let item: WindowItem
    let appRanges: [NSRange]
    let titleRanges: [NSRange]
}

/// Swift face of the Rust search core (core/src). Main thread only.
final class SearchEngine {
    private let engine: OpaquePointer
    private var itemsByID: [UInt64: WindowItem] = [:]

    init(learnFile: URL?) {
        if let path = learnFile?.path {
            engine = ct_engine_new(path)
        } else {
            engine = ct_engine_new(nil)
        }
    }

    deinit {
        ct_engine_free(engine)
    }

    static var coreVersion: String { String(cString: ct_version()) }

    /// Replaces the candidates. `items` must be in MRU order (most recent first).
    func setItems(_ items: [WindowItem]) {
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Pack every string into one buffer so a single allocation backs all
        // the pointers handed to Rust (which copies them).
        var buffer: [UInt8] = []
        buffer.reserveCapacity(items.count * 64)
        var spans: [(app: Range<Int>, title: Range<Int>, key: Range<Int>)] = []
        spans.reserveCapacity(items.count)
        func append(_ s: String) -> Range<Int> {
            let start = buffer.count
            buffer.append(contentsOf: s.utf8)
            return start..<buffer.count
        }
        for item in items {
            spans.append((append(item.appName), append(item.isWindowless ? "" : item.searchTitle), append(item.learnKey)))
        }

        buffer.withUnsafeBufferPointer { raw in
            let base = raw.baseAddress
            var ctItems = [CtItem]()
            ctItems.reserveCapacity(items.count)
            for (rank, (item, span)) in zip(items, spans).enumerated() {
                ctItems.append(CtItem(
                    id: item.id,
                    app: base.map { $0 + span.app.lowerBound }, app_len: span.app.count,
                    title: base.map { $0 + span.title.lowerBound }, title_len: span.title.count,
                    key: base.map { $0 + span.key.lowerBound }, key_len: span.key.count,
                    mru: UInt32(rank)
                ))
            }
            ct_engine_set_items(engine, ctItems, ctItems.count)
        }
    }

    func search(_ query: String) -> [SearchResult] {
        var utf8 = Array(query.utf8)
        let count = utf8.withUnsafeMutableBufferPointer { ct_engine_search(engine, $0.baseAddress, $0.count) }
        var results: [SearchResult] = []
        results.reserveCapacity(count)
        var raw = CtResult()
        for i in 0..<count {
            guard ct_engine_result(engine, i, &raw), let item = itemsByID[raw.id] else { continue }
            results.append(SearchResult(
                item: item,
                appRanges: Self.ranges(raw.app_ranges, raw.app_ranges_len),
                titleRanges: Self.ranges(raw.title_ranges, raw.title_ranges_len)
            ))
        }
        return results
    }

    func record(query: String, for item: WindowItem) {
        var q = Array(query.utf8)
        var k = Array(item.learnKey.utf8)
        q.withUnsafeMutableBufferPointer { qp in
            k.withUnsafeMutableBufferPointer { kp in
                ct_engine_record(engine, qp.baseAddress, qp.count, kp.baseAddress, kp.count)
            }
        }
    }

    func clearLearning() {
        ct_engine_clear_learning(engine)
    }

    private static func ranges(_ ptr: UnsafePointer<CtRange>?, _ len: Int) -> [NSRange] {
        guard let ptr, len > 0 else { return [] }
        return UnsafeBufferPointer(start: ptr, count: len).map { NSRange(location: Int($0.start), length: Int($0.len)) }
    }
}
