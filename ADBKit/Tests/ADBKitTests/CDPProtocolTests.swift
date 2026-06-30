import Foundation
import Testing
@testable import ADBKit

/// Pure tests for the CDP framing: request shapes and decoding of the replies
/// and events a console relies on.
@Suite struct CDPProtocolTests {
    // MARK: - Requests

    @Test func evaluateRequestUsesReplDefaults() {
        let request = CDP.request(id: 7, method: "Runtime.evaluate", params: CDP.evaluateParams(expression: "1 + 1"))
        #expect(request["id"]?.intValue == 7)
        #expect(request["method"]?.stringValue == "Runtime.evaluate")
        let params = request["params"]
        #expect(params?["expression"]?.stringValue == "1 + 1")
        #expect(params?["replMode"]?.boolValue == true)
        #expect(params?["includeCommandLineAPI"]?.boolValue == true)
        #expect(params?["generatePreview"]?.boolValue == true)
        #expect(params?["awaitPromise"]?.boolValue == true)
        #expect(params?["objectGroup"]?.stringValue == "console")
        // The result must stay a handle so it can be expanded and released.
        #expect(params?["returnByValue"]?.boolValue == false)
    }

    @Test func evaluateRequestPreservesExpressionVerbatim() {
        // An expression must round-trip exactly — no quoting/escaping mangling.
        let expression = #"({ a: "x", re: /~~~ y ~~~/ })"#
        let params = CDP.evaluateParams(expression: expression)
        #expect(params["expression"]?.stringValue == expression)
        let data = try? JSONEncoder().encode(CDP.request(id: 1, method: "Runtime.evaluate", params: params))
        let decoded = data.flatMap { CDP.parseIncoming($0) }
        // It decodes back as a (request-shaped) response with our id.
        if case let .response(id, _, _) = decoded { #expect(id == 1) } else { Issue.record("expected id round-trip") }
    }

    @Test func getPropertiesRequestRequestsOwnProperties() {
        let params = CDP.getPropertiesParams(objectId: "{\"id\":1}")
        #expect(params["objectId"]?.stringValue == "{\"id\":1}")
        #expect(params["ownProperties"]?.boolValue == true)
    }

    // MARK: - Incoming classification

    @Test func classifiesResponseAndEvent() {
        let response = CDP.parseIncoming(Data(#"{"id":3,"result":{"x":1}}"#.utf8))
        guard case let .response(id, result, error) = response else { Issue.record("expected response"); return }
        #expect(id == 3)
        #expect(result?["x"]?.intValue == 1)
        #expect(error == nil)

        let event = CDP.parseIncoming(Data(#"{"method":"Runtime.consoleAPICalled","params":{"type":"log"}}"#.utf8))
        guard case let .event(method, params) = event else { Issue.record("expected event"); return }
        #expect(method == "Runtime.consoleAPICalled")
        #expect(params["type"]?.stringValue == "log")
    }

    @Test func decodesProtocolError() {
        let response = CDP.parseIncoming(Data(#"{"id":4,"error":{"code":-32000,"message":"boom"}}"#.utf8))
        guard case let .response(_, _, error) = response else { Issue.record("expected response"); return }
        #expect(error?.code == -32000)
        #expect(error?.message == "boom")
    }

    // MARK: - Evaluate outcomes

    @Test func evaluateValueDecodesPrimitive() {
        let result = try? JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"result":{"type":"number","value":4,"description":"4"}}"#.utf8))
        guard case let .value(object) = EvalOutcome.from(result: result) else { Issue.record("expected value"); return }
        #expect(object.type == "number")
        #expect(object.description == "4")
        #expect(object.value?.doubleValue == 4)
    }

    @Test func evaluateExceptionIsNotATransportError() {
        // A thrown JS error rides in the successful reply as exceptionDetails.
        let json = #"""
        {"result":{"type":"object","subtype":"error"},
         "exceptionDetails":{"text":"Uncaught","exception":{"type":"object","subtype":"error",
           "description":"ReferenceError: foo is not defined\n  at <anonymous>:1:1"},
           "lineNumber":0,"columnNumber":0}}
        """#
        let result = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case let .error(details) = EvalOutcome.from(result: result) else { Issue.record("expected error"); return }
        #expect(details.message.contains("ReferenceError"))
    }

    @Test func evaluateMissingResultIsUndefined() {
        guard case let .value(object) = EvalOutcome.from(result: .object([:])) else {
            Issue.record("expected value"); return
        }
        #expect(object.type == "undefined")
    }

    // MARK: - RemoteObject + preview

    @Test func remoteObjectExposesExpandabilityAndPreview() {
        let json = #"""
        {"type":"object","className":"Object","description":"Object","objectId":"{\"id\":2}",
         "preview":{"type":"object","description":"Object","overflow":false,
           "properties":[{"name":"id","type":"number","value":"1"},{"name":"name","type":"string","value":"x"}]}}
        """#
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let object = RemoteObject(json: value ?? .null)
        #expect(object.isExpandable)
        #expect(object.objectId == "{\"id\":2}")
        #expect(object.preview?.properties.count == 2)
        #expect(object.preview?.properties.first?.name == "id")
    }

    @Test func nullIsNotExpandable() {
        let object = RemoteObject(json: .object(["type": .string("object"), "subtype": .string("null")]))
        #expect(!object.isExpandable)
    }

    @Test func primitiveStringIsNotExpandable() {
        let object = RemoteObject(json: .object(["type": .string("string"), "value": .string("hi")]))
        #expect(!object.isExpandable)
        #expect(object.value?.stringValue == "hi")
    }

    // MARK: - Console event

    @Test func consoleEventDecodesTypeAndArgs() {
        let json = #"""
        {"type":"warning","args":[{"type":"string","value":"watch out"},
          {"type":"number","value":42,"description":"42"}],"timestamp":1700000000000}
        """#
        let params = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let call = ConsoleAPICall(params: params ?? .null)
        #expect(call.type == "warning")
        #expect(call.args.count == 2)
        #expect(call.args.first?.value?.stringValue == "watch out")
        #expect(call.timestamp == 1_700_000_000_000)
    }

    // MARK: - getProperties

    @Test func parsesOwnPropertiesAndSkipsValuelessAccessors() {
        let json = #"""
        {"result":[
          {"name":"id","value":{"type":"number","value":1,"description":"1"},"isOwn":true,"enumerable":true},
          {"name":"hidden","get":{"type":"function"},"isOwn":true,"enumerable":true}
        ]}
        """#
        let result = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let properties = CDPProperty.parse(result)
        #expect(properties.count == 1)
        #expect(properties.first?.name == "id")
        #expect(properties.first?.value?.value?.doubleValue == 1)
    }

    // MARK: - Stack frames

    // MARK: - inlineSummary across all data types (real Hermes shapes)

    private func remote(_ json: String) -> RemoteObject {
        RemoteObject(json: (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null)
    }

    @Test func inlineSummaryRendersPrimitives() {
        #expect(remote(#"{"type":"string","value":"hi"}"#).inlineSummary == "\"hi\"")
        #expect(remote(#"{"type":"number","value":42}"#).inlineSummary == "42")
        #expect(remote(#"{"type":"number","value":3.5}"#).inlineSummary == "3.5")
        #expect(remote(#"{"type":"boolean","value":true}"#).inlineSummary == "true")
        #expect(remote(#"{"type":"undefined"}"#).inlineSummary == "undefined")
        #expect(remote(#"{"type":"object","subtype":"null","value":null}"#).inlineSummary == "null")
        #expect(remote(#"{"type":"symbol","description":"Symbol(sym)"}"#).inlineSummary == "Symbol(sym)")
    }

    @Test func inlineSummaryRendersHermesUnserializablesAndBigInt() {
        // Hermes: -0 / Infinity / NaN have description + unserializableValue, no value.
        #expect(remote(#"{"type":"number","description":"-0","unserializableValue":"-0"}"#).inlineSummary == "-0")
        #expect(remote(#"{"type":"number","description":"Infinity","unserializableValue":"Infinity"}"#).inlineSummary == "Infinity")
        #expect(remote(#"{"type":"number","description":"NaN","unserializableValue":"NaN"}"#).inlineSummary == "NaN")
        // Hermes reports bigint as type "".
        #expect(remote(#"{"type":"","description":"123n","unserializableValue":"123n"}"#).inlineSummary == "123n")
    }

    @Test func inlineSummaryRendersFunctionsAndErrors() {
        #expect(remote(#"{"type":"function","description":"function adder(a0, a1) { [bytecode] }"}"#).inlineSummary == "ƒ adder(a0, a1)")
        #expect(remote(#"{"type":"object","subtype":"error","description":"Error: boom\n   at x:1:1"}"#).inlineSummary == "Error: boom")
    }

    @Test func inlineSummaryRendersArraysAndObjectsFromPreview() {
        let array = #"""
        {"type":"object","subtype":"array","description":"Array(3)","preview":{"type":"object","subtype":"array",
         "description":"Array(3)","overflow":false,"properties":[{"name":"0","type":"number","value":"1"},
         {"name":"1","type":"string","value":"two"},{"name":"2","type":"object","value":"Array(2)"}]}}
        """#
        #expect(remote(array).inlineSummary == "[1, \"two\", Array(2)]")

        let object = #"""
        {"type":"object","className":"Object","description":"Object","preview":{"type":"object","description":"Object",
         "overflow":true,"properties":[{"name":"id","type":"number","value":"1"},{"name":"name","type":"string","value":"x"}]}}
        """#
        #expect(remote(object).inlineSummary == "{id: 1, name: \"x\", …}")
    }

    @Test func tokensCarrySemanticKindsForColoring() {
        let object = remote(#"""
        {"type":"object","description":"Object","preview":{"type":"object","description":"Object","overflow":false,
         "properties":[{"name":"id","type":"number","value":"1"},{"name":"name","type":"string","value":"x"}]}}
        """#)
        let tokens = object.tokens
        #expect(tokens.contains { $0.text == "id" && $0.kind == .key })
        #expect(tokens.contains { $0.text == "1" && $0.kind == .number })
        #expect(tokens.contains { $0.text == "\"x\"" && $0.kind == .string })
        #expect(remote(#"{"type":"string","value":"hi"}"#).tokens.first?.kind == .string)
        #expect(remote(#"{"type":"boolean","value":true}"#).tokens.first?.kind == .boolean)
        #expect(remote(#"{"type":"object","subtype":"null","value":null}"#).tokens.first?.kind == .null)
    }

    @Test func stackFrameDisplayIsOneBasedWithFile() {
        let frame = CDPCallFrame(json: .object([
            "functionName": .string("render"),
            "url": .string("index.bundle"),
            "lineNumber": .number(41),
            "columnNumber": .number(2),
        ]))
        #expect(frame.display == "render  index.bundle:42")
    }
}
