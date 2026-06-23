import Foundation
import Testing

@testable import GalavantAI

@Suite struct AnthropicWireTests {
  @Test("request body carries model, max_tokens, system, stream, and messages")
  func requestBodyShape() throws {
    let request = ModelRequest(
      tier: .frontier(.anthropic),
      system: "You are helpful.",
      messages: [.user("Hi"), .assistant("Hello"), .user("Bye")],
      maxTokens: 256
    )
    let data = try AnthropicWire.requestData(for: request, model: "claude-opus-4-8", stream: true)
    let json = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(json["model"] as? String == "claude-opus-4-8")
    #expect(json["max_tokens"] as? Int == 256)
    #expect(json["system"] as? String == "You are helpful.")
    #expect(json["stream"] as? Bool == true)
    // Adaptive-thinking-only model: no sampling params may be sent (they 400).
    #expect(json["temperature"] == nil)
    #expect(json["top_p"] == nil)

    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 3)
    #expect(messages.first?["role"] as? String == "user")
    #expect(messages.first?["content"] as? String == "Hi")
    #expect(messages[1]["role"] as? String == "assistant")
  }

  @Test("system is omitted when nil")
  func requestBodyOmitsNilSystem() throws {
    let request = ModelRequest(messages: [.user("Hi")])
    let data = try AnthropicWire.requestData(for: request, model: "m", stream: false)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["system"] == nil)
    #expect(json["stream"] as? Bool == false)
  }

  @Test("non-stream response concatenates text blocks and reads stop_reason")
  func decodeResponse() throws {
    let body = """
      {"content":[{"type":"text","text":"Hello, "},{"type":"text","text":"world"}],
      "stop_reason":"end_turn"}
      """
    let response = try AnthropicWire.response(from: Data(body.utf8))
    #expect(response.text == "Hello, world")
    #expect(response.stopReason == "end_turn")
  }

  @Test("malformed response throws")
  func decodeMalformed() {
    #expect(throws: ModelClientError.malformedResponse) {
      try AnthropicWire.response(from: Data("not json".utf8))
    }
  }

  @Test("error envelope message is extracted")
  func errorMessage() {
    let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
    #expect(AnthropicWire.errorMessage(from: Data(body.utf8)) == "invalid x-api-key")
  }

  @Test("SSE frames decode to deltas, stop, and other")
  func streamEvents() {
    let delta = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
    #expect(AnthropicWire.streamEvent(fromData: Data(delta.utf8)) == .delta("Hi"))

    let stop = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#
    #expect(AnthropicWire.streamEvent(fromData: Data(stop.utf8)) == .stop(reason: "end_turn"))

    let start = #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
    #expect(AnthropicWire.streamEvent(fromData: Data(start.utf8)) == .other)
  }

  @Test("SSE data-line payloads are extracted, non-data lines ignored")
  func sseDataPayload() {
    #expect(AnthropicModelClient.sseDataPayload("data: {\"a\":1}") == "{\"a\":1}")
    #expect(AnthropicModelClient.sseDataPayload("event: message_stop") == nil)
    #expect(AnthropicModelClient.sseDataPayload("") == nil)
  }

  @Test("tools serialize as input_schema with nested keys left verbatim")
  func requestBodyTools() throws {
    let tool = ModelTool(
      name: "query_pool",
      description: "Filter the idea pool",
      inputSchema: [
        "type": "object",
        "properties": ["includeVisited": ["type": "boolean"]],
        "required": ["includeVisited"],
      ]
    )
    let request = ModelRequest(
      tier: .frontier(.anthropic), messages: [.user("hi")], tools: [tool])
    let data = try AnthropicWire.requestData(for: request, model: "m", stream: false)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.first?["name"] as? String == "query_pool")
    let schema = try #require(tools.first?["input_schema"] as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: Any])
    // The nested camelCase property key must survive — not snake-cased to a
    // different name the tool dispatcher wouldn't recognize.
    #expect(properties["includeVisited"] != nil)
    #expect(properties["include_visited"] == nil)
  }

  @Test("an assistant tool_use turn and a user tool_result turn round-trip on the wire")
  func toolLoopMessages() throws {
    let assistant = ModelMessage(
      role: .assistant,
      content: [
        .text("Let me check."),
        .toolUse(ModelToolCall(id: "toolu_1", name: "query_pool", input: ["q": "food"])),
      ]
    )
    let result = ModelMessage(
      role: .user,
      content: [.toolResult(toolUseID: "toolu_1", text: "2 ideas", isError: false)]
    )
    let request = ModelRequest(messages: [.user("hi"), assistant, result])
    let data = try AnthropicWire.requestData(for: request, model: "m", stream: false)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])

    let assistantBlocks = try #require(messages[1]["content"] as? [[String: Any]])
    #expect(assistantBlocks[0]["type"] as? String == "text")
    #expect(assistantBlocks[1]["type"] as? String == "tool_use")
    #expect(assistantBlocks[1]["id"] as? String == "toolu_1")

    let resultBlocks = try #require(messages[2]["content"] as? [[String: Any]])
    #expect(resultBlocks[0]["type"] as? String == "tool_result")
    #expect(resultBlocks[0]["tool_use_id"] as? String == "toolu_1")
    #expect(resultBlocks[0]["content"] as? String == "2 ideas")
    #expect(resultBlocks[0]["is_error"] as? Bool == false)
  }

  @Test("response decodes tool_use blocks into tool calls alongside text")
  func decodeToolUseResponse() throws {
    let body = """
      {"content":[
        {"type":"text","text":"Looking…"},
        {"type":"tool_use","id":"toolu_9","name":"create_idea","input":{"name":"Noma"}}
      ],"stop_reason":"tool_use"}
      """
    let response = try AnthropicWire.response(from: Data(body.utf8))
    #expect(response.text == "Looking…")
    #expect(response.stopReason == "tool_use")
    #expect(response.toolCalls.count == 1)
    #expect(response.toolCalls.first?.name == "create_idea")
    #expect(response.toolCalls.first?.input.string("name") == "Noma")
  }
}

@Suite struct TieredModelClientTests {
  @Test("complete routes through the protocol")
  func completeThroughProtocol() async throws {
    let client = TieredModelClient(onDevice: StubModelClient.echo, frontier: nil)
    let response = try await client.complete(.init(prompt: "ping"))
    #expect(response.text == "ping")
  }

  @Test("stream routes through the protocol")
  func streamThroughProtocol() async throws {
    let client = TieredModelClient(onDevice: StubModelClient.echo, frontier: nil)
    var chunks: [String] = []
    for try await chunk in client.stream(.init(prompt: "pong")) {
      chunks.append(chunk.text)
    }
    #expect(chunks == ["pong"])
  }

  @Test("a frontier request degrades to on-device when no key is configured")
  func frontierDegradesWithoutKey() async throws {
    let client = TieredModelClient(
      onDevice: StubModelClient.constant("on-device"), frontier: nil
    )
    #expect(client.isFrontierAvailable == false)
    let response = try await client.complete(
      .init(tier: .frontier(.anthropic), prompt: "x")
    )
    #expect(response.text == "on-device")
  }

  @Test("a frontier request uses the frontier backend when a key is configured")
  func frontierUsedWhenAvailable() async throws {
    let client = TieredModelClient(
      onDevice: StubModelClient.constant("on-device"),
      frontier: StubModelClient.constant("frontier")
    )
    #expect(client.isFrontierAvailable == true)
    let response = try await client.complete(
      .init(tier: .frontier(.anthropic), prompt: "x")
    )
    #expect(response.text == "frontier")
  }

  @Test("an on-device request never touches the frontier backend")
  func onDeviceStaysOnDevice() async throws {
    let client = TieredModelClient(
      onDevice: StubModelClient.constant("on-device"),
      frontier: StubModelClient.constant("frontier")
    )
    let response = try await client.complete(.init(tier: .onDevice, prompt: "x"))
    #expect(response.text == "on-device")
  }
}

@Suite struct APIKeyStoreTests {
  @Test("in-memory store round-trips and clears a key")
  func roundTrip() {
    let store = APIKeyStore.inMemory()
    #expect(store.key(.anthropic) == nil)

    store.setKey("sk-ant-123", for: .anthropic)
    #expect(store.key(.anthropic) == "sk-ant-123")

    store.setKey(nil, for: .anthropic)
    #expect(store.key(.anthropic) == nil)
  }

  @Test("blank keys are treated as no key")
  func blankIsCleared() {
    let store = APIKeyStore.inMemory()
    store.setKey("sk-ant-123", for: .anthropic)
    store.setKey("   ", for: .anthropic)
    #expect(store.key(.anthropic) == nil)
  }

  @Test("whitespace is trimmed before storage")
  func trims() {
    let store = APIKeyStore.inMemory()
    store.setKey("  sk-ant-xyz\n", for: .anthropic)
    #expect(store.key(.anthropic) == "sk-ant-xyz")
  }
}
