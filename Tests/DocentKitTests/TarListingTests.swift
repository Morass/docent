import XCTest
@testable import DocentKit

final class TarListingTests: XCTestCase {
    /// Real `tar -tvf` output. The third column is the owner, and reading it as the size is
    /// a guard that never fires.
    func testTheSizeColumnIsTheFifth() {
        let listing = """
        -rw-r--r--  0 someone staff    2560 18 Sep 21:44 Thing.docset/Contents/Info.plist
        -rw-r--r--  0 someone staff 1048576 18 Sep 21:44 Thing.docset/Contents/Resources/docSet.dsidx
        """
        XCTAssertEqual(TarListing.unpackedBytes(listing), 2560 + 1_048_576)
    }

    func testDirectoriesAndOddLinesAreSkippedNotCounted() {
        let listing = """
        drwxr-xr-x  0 someone staff       0 18 Sep 21:44 Thing.docset/
        garbage
        -rw-r--r--  0 someone staff     100 18 Sep 21:44 Thing.docset/a file with spaces.html
        """
        XCTAssertEqual(TarListing.unpackedBytes(listing), 100)
    }

    func testAnEmptyListingIsZero() {
        XCTAssertEqual(TarListing.unpackedBytes(""), 0)
    }
}
