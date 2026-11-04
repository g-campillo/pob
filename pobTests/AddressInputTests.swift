import Foundation
import Testing
@testable import pob

@Suite struct AddressInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com  ", "https://example.com"),
        ("EXAMPLE.com/Path", "https://EXAMPLE.com/Path"),
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("http://example.com", "http://example.com"),
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8080/health", "http://127.0.0.1:8080/health"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("[::1]:3000", "http://[::1]:3000"),
        ("my-server.local", "http://my-server.local"),
        ("file:///tmp/a.html", "file:///tmp/a.html"),
        ("about:blank", "about:blank"),
    ])
    func recognizesAddresses(input: String, expected: String) {
        #expect(AddressInput.classify(input) == .url(URL(string: expected)!))
    }

    @Test(arguments: [
        ("hello world", "https://www.google.com/search?q=hello%20world"),
        ("swift", "https://www.google.com/search?q=swift"),
        ("foo.bar baz", "https://www.google.com/search?q=foo.bar%20baz"),
        ("a&b=c", "https://www.google.com/search?q=a%26b%3Dc"),
        ("javascript:alert(1)", "https://www.google.com/search?q=javascript%3Aalert(1)"),
    ])
    func treatsEverythingElseAsSearch(input: String, expected: String) {
        #expect(AddressInput.classify(input) == .search(URL(string: expected)!))
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyInputIsNothing(input: String) {
        #expect(AddressInput.classify(input) == nil)
    }
}
