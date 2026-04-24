import Foundation

extension Array where Element: Identifiable {
    /// Returns a new array by removing duplicate elements based on their `id`.
    /// Preserves the original order.
    public func removeDuplicates() -> [Element] {
        removeDuplicates(by: \.id)
    }
}

extension Array {
    /// Returns a new array by removing duplicate elements based on a key path.
    /// Preserves the original order.
    public func removeDuplicates<T: Hashable>(by keyPath: KeyPath<Element, T>) -> [Element] {
        var seen = Set<T>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }

    /// Returns a new array by removing duplicate elements based on a transformation closure.
    /// Preserves the original order.
    public func removeDuplicates<T: Hashable>(on transform: (Element) -> T) -> [Element] {
        var seen = Set<T>()
        return filter { seen.insert(transform($0)).inserted }
    }
}
