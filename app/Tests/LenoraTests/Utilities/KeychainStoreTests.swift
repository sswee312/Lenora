import Foundation
import Security
import Testing

@testable import Lenora

struct KeychainStoreUpsertTests {
    private final class Calls {
        var log: [String] = []
    }

    private func upsert(update: OSStatus, add: OSStatus = errSecSuccess, delete: OSStatus = errSecSuccess) -> (Bool, [String]) {
        let calls = Calls()
        let saved = KeychainStore.upsert(
            update: { calls.log.append("update"); return update },
            add: { calls.log.append("add"); return add },
            delete: { calls.log.append("delete"); return delete }
        )
        return (saved, calls.log)
    }

    @Test func updatesAnExistingItem() {
        let (saved, calls) = upsert(update: errSecSuccess)
        #expect(saved)
        #expect(calls == ["update"])
    }

    @Test func addsWhenNoItemExists() {
        let (saved, calls) = upsert(update: errSecItemNotFound)
        #expect(saved)
        #expect(calls == ["update", "add"])
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed])
    func replacesAnItemThisBuildCannotModify(status: OSStatus) {
        let (saved, calls) = upsert(update: status)
        #expect(saved)
        #expect(calls == ["update", "delete", "add"])
    }

    @Test func failsWithoutAddingWhenTheUnmodifiableItemCannotBeDeleted() {
        let (saved, calls) = upsert(update: errSecAuthFailed, delete: errSecAuthFailed)
        #expect(!saved)
        #expect(calls == ["update", "delete"])
    }

    @Test func otherUpdateFailuresKeepTheExistingItem() {
        let (saved, calls) = upsert(update: errSecUserCanceled)
        #expect(!saved)
        #expect(calls == ["update"])
    }
}
