import Foundation

/// Reading `tar -tvf` output, which is not as simple as it looks.
///
/// A line is `-rw-r--r--  0 owner group  2560 18 Sep 21:44 path with spaces`: the size is
/// the *fifth* field, not the third, and the path may hold spaces — so a name is never read
/// from here at all (`tar -tf` gives one whole path per line for that).
public enum TarListing {
    public static func unpackedBytes(_ listing: String) -> Int {
        var total = 0
        for line in listing.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 5, let size = Int(columns[4]) else { continue }
            total += size
        }
        return total
    }
}
