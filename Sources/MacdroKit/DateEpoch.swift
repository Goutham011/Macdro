import Foundation

public enum DateEpoch {
    public static func seconds(_ date: Date) -> UInt64 {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite, interval > 0 else {
            return 0
        }
        guard interval < 9_223_372_036_854_775_807.0 else {
            return UInt64.max
        }
        return UInt64(interval)
    }
}
