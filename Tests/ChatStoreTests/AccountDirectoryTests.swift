import ChatModel
import Foundation
import Testing

@testable import ChatStore

extension ExportLockSuites {
    @Suite struct AccountDirectoryTests {
        private func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        }

        @Test func layoutUsesOnlyTheLocalAccountID() {
            let temp = TempDirectory()
            let account = AccountID()
            let directory = AccountDirectory(root: temp.url, account: account)
            let id = account.description
            #expect(directory.storeURL.path == temp.url.path + "/accounts/\(id)/store.sqlite")
            #expect(directory.mediaURL.path == temp.url.path + "/accounts/\(id)/media")
            #expect(directory.exportsURL.path == temp.url.path + "/exports/\(id)")
            #expect(UUID(uuidString: id) != nil)
        }

        @Test func createMakesOwnerOnlyDirectories() throws {
            let temp = TempDirectory()
            let directory = AccountDirectory(root: temp.url, account: AccountID())
            #expect(!directory.storeExists())
            try directory.create()
            try directory.createExports()
            try directory.create()
            for url in [
                temp.url, temp.url.appendingPathComponent("accounts"), directory.accountURL, directory.mediaURL,
                temp.url.appendingPathComponent("exports"), directory.exportsURL,
            ] {
                #expect(try mode(url) == 0o700, "\(url.lastPathComponent)")
            }
        }

        @Test func storeExistsFollowsTheStoreFile() throws {
            let temp = TempDirectory()
            let account = AccountID()
            let directory = AccountDirectory(root: temp.url, account: account)
            let store = try SQLiteAccountStore.open(directory: directory, key: .random(for: account))
            #expect(directory.storeExists())
            store.close()
        }

        @Test func deleteAccountFilesRemovesEverythingAndToleratesAbsence() throws {
            let temp = TempDirectory()
            let account = AccountID()
            let other = AccountID()
            let directory = AccountDirectory(root: temp.url, account: account)
            try directory.deleteAccountFiles()

            let store = try SQLiteAccountStore.open(directory: directory, key: .random(for: account))
            let sibling = try SQLiteAccountStore.open(
                directory: AccountDirectory(root: temp.url, account: other), key: .random(for: other))
            try Data("x".utf8).write(to: directory.mediaURL.appendingPathComponent("blob"))
            store.close()
            sibling.close()

            try directory.deleteAccountFiles()
            #expect(!directory.storeExists())
            #expect(!FileManager.default.fileExists(atPath: directory.accountURL.path))
            #expect(AccountDirectory(root: temp.url, account: other).storeExists())
            try directory.deleteAccountFiles()
        }

        @Test func wipeExportsRemovesPlaintextFilesAndToleratesAbsence() throws {
            let temp = TempDirectory()
            let directory = AccountDirectory(root: temp.url, account: AccountID())
            try directory.wipeExports()
            try directory.createExports()
            try Data("plain".utf8).write(to: directory.exportsURL.appendingPathComponent("a.txt"))
            try directory.wipeExports()
            #expect(!FileManager.default.fileExists(atPath: directory.exportsURL.path))
            try directory.wipeExports()
        }

        @Test func defaultRootIsUnderApplicationSupport() throws {
            let root = try AccountDirectory.defaultRoot()
            #expect(root.lastPathComponent == "io.github.drekinov.gchat-mac")
            #expect(root.path.contains("Application Support"))
        }
    }
}
