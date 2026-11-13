import Foundation
import Testing

/// The bundled `CREDITS.md` (Settings → Credits) and the third-party license files it points to. MIT data and code
/// ship with their copyright notice and license text, so a license file the credits name must be in the bundle.
@Suite struct CreditsLicenseFilesTests {
    private func bundledText(_ name: String, _ ext: String) throws -> String {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: ext), "\(name).\(ext) isn't bundled")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyLicenseFileTheCreditsNameIsBundled() throws {
        let credits = try bundledText("CREDITS", "md")
        let named = credits.matches(of: /License: (\S+\.txt) in the app bundle/).map { String($0.output.1) }
        #expect(named.contains("exercises-dataset-LICENSE.txt"))
        #expect(named.contains("body-highlighter-LICENSE.txt"))
        for file in named {
            #expect(Bundle.main.url(forResource: file, withExtension: nil) != nil, "\(file) isn't bundled")
        }
    }

    @Test func exerciseDataShipsItsMITNotice() throws {
        let notice = "Copyright (c) 2026 Hasan Emir Yıldırım"
        let license = try bundledText("exercises-dataset-LICENSE", "txt")
        #expect(license.hasPrefix("MIT License"))
        #expect(license.contains(notice))
        #expect(try bundledText("CREDITS", "md").contains(notice))
    }

    /// openGym only inspired the data model and naming; the credit mustn't read as if its AGPL code ships.
    @Test func openGymCreditSaysNoneOfItsCodeShips() throws {
        let credits = try bundledText("CREDITS", "md")
        #expect(credits.contains("No openGym code or data is included."))
        #expect(!credits.contains("AGPL"))
    }
}
