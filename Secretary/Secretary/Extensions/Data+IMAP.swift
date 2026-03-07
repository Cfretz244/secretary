import Foundation

extension Data {
    /// Find the range of a byte sequence within this data.
    func range(of search: Data) -> Range<Data.Index>? {
        guard search.count <= self.count else { return nil }
        let end = self.count - search.count
        for i in 0...end {
            if self[i..<i+search.count] == search {
                return i..<i+search.count
            }
        }
        return nil
    }
}
