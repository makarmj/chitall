import Foundation
import XCTest
@testable import ChitallCore

final class ArchiveTests: XCTestCase {
    func testStoredZipYieldsTheSameBookAndFingerprint() throws {
        let plain = try BookImporter.importBook(data: Fixtures.data("sample-utf8.fb2"))
        let zipped = try BookImporter.importBook(data: Fixtures.data("sample-stored.fb2.zip"))
        XCTAssertEqual(zipped.archiveEntryName, "sample.fb2")
        XCTAssertNil(plain.archiveEntryName)
        XCTAssertEqual(zipped.sourceData, plain.sourceData)
        XCTAssertEqual(zipped.fingerprint, plain.fingerprint)
        XCTAssertEqual(zipped.book.allBlocks, plain.book.allBlocks)
    }

    func testDeflatedZip() throws {
        let data = try Fixtures.data("sample-deflated.fb2.zip")
        let archive = try ZipArchive(data: data)
        XCTAssertEqual(archive.entries.map(\.name), ["book/sample.fb2"])
        XCTAssertEqual(archive.entries.first?.method, 8)
        if ZipArchive.systemInflater != nil {
            let imported = try BookImporter.importBook(data: data)
            XCTAssertEqual(imported.sourceData, try Fixtures.data("sample-utf8.fb2"))
        } else {
            // Apple's Compression framework is not available on Linux/Windows.
            XCTAssertThrowsImportError(try BookImporter.importBook(data: data), .unsupportedArchive("deflate is not available on this platform"))
        }
    }

    func testZipWithoutFB2() throws {
        XCTAssertThrowsImportError(try BookImporter.importBook(data: Fixtures.data("no-fb2.zip")), .archiveWithoutFB2)
    }

    func testDamagedZip() throws {
        let data = try Fixtures.data("sample-stored.fb2.zip")
        XCTAssertThrowsError(try BookImporter.importBook(data: data.prefix(200))) { error in
            guard case .damagedArchive = error as? BookImportError else { return XCTFail("got \(error)") }
        }
        var corrupted = [UInt8](data)
        corrupted[120] ^= 0xFF // inside the stored payload: the CRC must catch it
        XCTAssertThrowsError(try BookImporter.importBook(data: Data(corrupted))) { error in
            guard case .damagedArchive = error as? BookImportError else { return XCTFail("got \(error)") }
        }
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testFileSizeLimit() {
        XCTAssertThrowsImportError(
            try BookImporter.importBook(data: Data(count: BookImporter.maximumFileSize + 1)),
            .fileTooLarge(bytes: BookImporter.maximumFileSize + 1, limit: BookImporter.maximumFileSize)
        )
    }
}

final class FingerprintTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }.joined()
    }

    func testPortableSHA256Vectors() {
        XCTAssertEqual(hex(PortableSHA256.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(PortableSHA256.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(PortableSHA256.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            hex(PortableSHA256.hash(Data(repeating: 0x61, count: 1000))),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        )
    }

    func testFingerprintMatchesPortableImplementationAndPythonHashlib() throws {
        let data = try Fixtures.data("sample-utf8.fb2")
        XCTAssertEqual(Fingerprint.of(data), "sha256:" + hex(PortableSHA256.hash(data)))
        // Computed with Python's hashlib when the fixture was created.
        XCTAssertEqual(Fingerprint.of(data), "sha256:3b05d7187e1ec04ffa75d99a61f526a7ad8bdf3edf5e9de09f8cb055a1a2591f")
        XCTAssertEqual(Fingerprint.short(Fingerprint.of(data)), "sha256:3b05d718")
    }
}
