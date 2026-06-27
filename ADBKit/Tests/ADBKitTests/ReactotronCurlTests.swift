import Foundation
import Testing
@testable import ADBKit

@Suite struct ReactotronCurlTests {
    @Test func getWithoutBodyHasNoMethodOrData() {
        let curl = ReactotronCurl.command(method: "GET", url: "https://x.test/items", request: nil)
        #expect(curl.contains("curl"))
        #expect(curl.contains("'https://x.test/items'"))
        #expect(!curl.contains("-X"))
        #expect(!curl.contains("--data"))
    }

    @Test func getWithEmptyObjectDataStaysBodylessGet() {
        // Reactotron often records `data: {}` for a GET — it must not gain a body
        // (and therefore must not flip to POST).
        let request = JSONValue.object(["data": .object([:])])
        let curl = ReactotronCurl.command(method: "get", url: "https://x.test", request: request)
        #expect(!curl.contains("--data"))
        #expect(!curl.contains("-X"))
    }

    @Test func getWithRealBodyKeepsGetMethod() {
        // The reported bug: a GET with a body must stay GET, not silently POST.
        let request = JSONValue.object(["data": .string("q=1")])
        let curl = ReactotronCurl.command(method: "GET", url: "https://x.test", request: request)
        #expect(curl.contains("-X GET"))
        #expect(curl.contains("--data 'q=1'"))
    }

    @Test func postWithBodySetsMethodAndData() {
        let request = JSONValue.object(["data": .string(#"{"a":1}"#)])
        let curl = ReactotronCurl.command(method: "POST", url: "https://x.test", request: request)
        #expect(curl.contains("-X POST"))
        #expect(curl.contains(#"--data '{"a":1}'"#))
    }

    @Test func putWithoutBodyStillSetsMethod() {
        let curl = ReactotronCurl.command(method: "PUT", url: "https://x.test", request: nil)
        #expect(curl.contains("-X PUT"))
        #expect(!curl.contains("--data"))
    }

    @Test func headersAreRenderedSortedAndQuoted() throws {
        let request = JSONValue.object([
            "headers": .object([
                "Authorization": .string("Bearer t"),
                "Accept": .string("application/json"),
            ]),
        ])
        let curl = ReactotronCurl.command(method: "GET", url: "https://x.test", request: request)
        #expect(curl.contains("-H 'Accept: application/json'"))
        #expect(curl.contains("-H 'Authorization: Bearer t'"))
        let accept = try #require(curl.range(of: "Accept"))
        let auth = try #require(curl.range(of: "Authorization"))
        #expect(accept.lowerBound < auth.lowerBound)
    }

    @Test func singleQuotesInValuesAreEscaped() {
        let request = JSONValue.object(["data": .string("it's")])
        let curl = ReactotronCurl.command(method: "POST", url: "https://x.test", request: request)
        #expect(curl.contains(#"--data 'it'\''s'"#))
    }

    @Test func objectBodyIsSerializedToJSON() {
        // Reactotron usually records the body as a JSON object, not a pre-encoded
        // string — the rawJSON path must serialize it and attach it.
        let request = JSONValue.object(["data": .object(["a": .number(1)])])
        let curl = ReactotronCurl.command(method: "POST", url: "https://x.test", request: request)
        #expect(curl.contains("-X POST"))
        #expect(curl.contains(#"--data '{"a":1}'"#))
    }

    @Test func nonEmptyArrayBodyIsAttached() {
        let request = JSONValue.object(["data": .array([.number(1), .number(2)])])
        let curl = ReactotronCurl.command(method: "POST", url: "https://x.test", request: request)
        #expect(curl.contains(#"--data '[1,2]'"#))
    }

    @Test func emptyArrayDataStaysBodyless() {
        let request = JSONValue.object(["data": .array([])])
        let curl = ReactotronCurl.command(method: "GET", url: "https://x.test", request: request)
        #expect(!curl.contains("--data"))
        #expect(!curl.contains("-X"))
    }

    @Test func nullAndEmptyStringDataStayBodyless() {
        for data: JSONValue in [.null, .string("")] {
            let request = JSONValue.object(["data": data])
            let curl = ReactotronCurl.command(method: "GET", url: "https://x.test", request: request)
            #expect(!curl.contains("--data"))
            #expect(!curl.contains("-X"))
        }
    }

    @Test func nonStringHeaderValueIsSerialized() {
        let request = JSONValue.object(["headers": .object(["X-Retry": .number(3)])])
        let curl = ReactotronCurl.command(method: "GET", url: "https://x.test", request: request)
        #expect(curl.contains("-H 'X-Retry: 3'"))
    }
}
