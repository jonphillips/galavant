import Foundation
import Testing

@testable import GalavantAI

/// The OpenAI Chat Completions wire (ADR-0014 multi-provider amendment). Mirrors
/// `AnthropicWireTests`; covers the three shape differences from Anthropic —
/// system-as-message, `tool`-role results, and stringified tool arguments — plus
/// the SSE `[DONE]` sentinel.
@Suite struct OpenAIWireTests {
  @Test("request body carries model, max_completion_tokens, stream, and a leading system message")
  func requestBodyShape() throws {
    let request = ModelRequest(
      tier: .frontier(.openai),
      system: "You are helpful.",
      messages: [.user("Hi"), .assistant("Hello"), .user("Bye")],
      maxTokens: 256
    )
    let data = try OpenAIWire.requestData(for: request, model: "gpt-x", stream: true)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["model"] as? String == "gpt-x")
    #expect(json["max_completion_tokens"] as? Int == 256)
    #expect(json["stream"] as? Bool == true)

    let messages = try #require(json["messages"] as? [[String: Any]])
    // System is prepended as a role:"system" message (OpenAI has no system field).
    #expect(messages.count == 4)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[0]["content"] as? String == "You are helpful.")
    #expect(messages[1]["role"] as? String == "user")
    #expect(messages[1]["content"] as? String == "Hi")
  }

  @Test("tools serialize as function with parameters, nested keys verbatim")
  func requestBodyTools() throws {
    let tool = ModelTool(
      name: "query_pool",
      description: "Filter the idea pool",
      inputSchema: ["type": "object", "properties": ["includeVisited": ["type": "boolean"]]]
    )
    let request = ModelRequest(tier: .frontier(.openai), messages: [.user("hi")], tools: [tool])
    let data = try OpenAIWire.requestData(for: request, model: "m", stream: false)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.first?["type"] as? String == "function")
    let function = try #require(tools.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "query_pool")
    let parameters = try #require(function["parameters"] as? [String: Any])
    let properties = try #require(parameters["properties"] as? [String: Any])
    #expect(properties["includeVisited"] != nil)
    #expect(properties["include_visited"] == nil)
  }

  @Test("assistant tool_use becomes tool_calls (stringified args); tool_result becomes a tool message")
  func toolLoopMessages() throws {
    let assistant = ModelMessage(
      role: .assistant,
      content: [
        .text("Let me check."),
        .toolUse(ModelToolCall(id: "call_1", name: "query_pool", input: ["q": "food"])),
      ]
    )
    let result = ModelMessage(
      role: .user,
      content: [.toolResult(toolUseID: "call_1", text: "2 ideas", isError: false)]
    )
    let request = ModelRequest(messages: [.user("hi"), assistant, result])
    let data = try OpenAIWire.requestData(for: request, model: "m", stream: false)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])

    // [user, assistant(+tool_calls), tool]
    #expect(messages.count == 3)
    let toolCalls = try #require(messages[1]["tool_calls"] as? [[String: Any]])
    #expect(toolCalls.first?["id"] as? String == "call_1")
    #expect(toolCalls.first?["type"] as? String == "function")
    let function = try #require(toolCalls.first?["function"] as? [String: Any])
    #expect(function["name"] as? String == "query_pool")
    // arguments is a JSON *string*, not an object.
    let argsString = try #require(function["arguments"] as? String)
    let args = try #require(
      try JSONSerialization.jsonObject(with: Data(argsString.utf8)) as? [String: Any])
    #expect(args["q"] as? String == "food")

    #expect(messages[2]["role"] as? String == "tool")
    #expect(messages[2]["tool_call_id"] as? String == "call_1")
    #expect(messages[2]["content"] as? String == "2 ideas")
  }

  @Test("response reads the first choice's text and finish_reason")
  func decodeResponse() throws {
    let body = """
      {"choices":[{"message":{"role":"assistant","content":"Hello, world"},
      "finish_reason":"stop"}]}
      """
    let response = try OpenAIWire.response(from: Data(body.utf8))
    #expect(response.text == "Hello, world")
    #expect(response.stopReason == "stop")
    #expect(response.toolCalls.isEmpty)
  }

  @Test("response decodes tool_calls, parsing arguments back from their JSON string")
  func decodeToolCalls() throws {
    let body = """
      {"choices":[{"message":{"role":"assistant","content":null,
      "tool_calls":[{"id":"call_9","type":"function",
      "function":{"name":"create_idea","arguments":"{\\"name\\":\\"Noma\\"}"}}]},
      "finish_reason":"tool_calls"}]}
      """
    let response = try OpenAIWire.response(from: Data(body.utf8))
    #expect(response.stopReason == "tool_calls")
    #expect(response.toolCalls.count == 1)
    #expect(response.toolCalls.first?.name == "create_idea")
    #expect(response.toolCalls.first?.input.string("name") == "Noma")
  }

  @Test("malformed response throws")
  func decodeMalformed() {
    #expect(throws: ModelClientError.malformedResponse) {
      try OpenAIWire.response(from: Data("not json".utf8))
    }
  }

  @Test("error envelope message is extracted")
  func errorMessage() {
    let body = #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#
    #expect(OpenAIWire.errorMessage(from: Data(body.utf8)) == "Incorrect API key provided")
  }

  @Test("SSE frames decode to deltas, stop, and other")
  func streamEvents() {
    let delta = #"{"choices":[{"delta":{"content":"Hi"}}]}"#
    #expect(OpenAIWire.streamEvent(fromData: Data(delta.utf8)) == .delta("Hi"))

    let stop = #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
    #expect(OpenAIWire.streamEvent(fromData: Data(stop.utf8)) == .stop(reason: "stop"))

    let empty = #"{"choices":[{"delta":{"role":"assistant"}}]}"#
    #expect(OpenAIWire.streamEvent(fromData: Data(empty.utf8)) == .other)
  }
}
