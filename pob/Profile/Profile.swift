import Foundation
import WebKit

struct Profile {
    let id: UUID

    static let initial = Profile(id: UUID(uuidString: "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")!)

    var dataStore: WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: id)
    }
}
