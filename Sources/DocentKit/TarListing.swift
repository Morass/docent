import Foundation

/// Reading `tar -tvf` output, which is not as simple as it looks.
///
/// A line is `-rw-r--r--  0 owner group  2560 18 Sep 21:44 path with spaces`. Splitting on
/// spaces and taking the fifth field is wrong the moment an owner or group name contains a
/// space — an archive can set those to anything, and `gname="0 0"` shifts the column so a
/// huge file is counted as nothing. The size is the last plain number *before the date*,
/// so the date is what this looks for.
public enum TarListing {
    static let months: Set<String> = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Is this column where the date starts? BSD tar writes `18 Sep 21:44`, GNU tar writes
    /// `2026-09-18 21:44`.
    static func isDateStart(_ columns: [Substring], _ index: Int) -> Bool {
        guard index < columns.count else { return false }
        let column = String(columns[index])
        if column.count == 10, column.filter({ $0 == "-" }).count == 2,
           Int(column.prefix(4)) != nil { return true }
        if let day = Int(column), day >= 1, day <= 31,
           index + 1 < columns.count, months.contains(String(columns[index + 1])) { return true }
        if months.contains(column) { return true }
        return false
    }

    public static func unpackedBytes(_ listing: String) -> Int {
        var total = 0
        for line in listing.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 4 else { continue }
            // Walk to the date and take the number in front of it.
            var date: Int? = nil
            for index in 3..<columns.count where isDateStart(columns, index) {
                date = index
                break
            }
            guard let date, date > 0, let size = Int(columns[date - 1]), size >= 0 else { continue }
            // An archive can declare sizes near Int.max; adding them up used to trap, which
            // is a crash before any cap could refuse the archive.
            let (sum, overflowed) = total.addingReportingOverflow(size)
            if overflowed { return Int.max }
            total = sum
        }
        return total
    }

    /// What a folder actually holds, which is the only number an archive cannot lie about.
    public static func bytesOnDisk(_ url: URL, stoppingAt limit: Int) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                         options: []) else { return 0 }
        var total = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += size
            if total > limit { return total }
        }
        return total
    }
}
