import Dependencies
import Foundation
import LLMClientKit
import GalavantSchema
import Synchronization
import Testing

@testable import GalavantChat

@MainActor
@Suite struct ChatModelTests {
  /// A context to talk about — a simple idea screen.
  private var ideaContext: ChatContext {
    .idea(ResolvedIdeaContext(idea: Idea(id: UUID(), name: "Noma", kind: .food)))
  }

  @Test("on-device path streams a text reply and never touches tools")
  func onDeviceStreamsText() async {
    let recorder = ToolRecorder()
    await withDependencies {
      // The echo backend replays the last user turn — enough to prove text flowed
      // through the on-device stream path.
      $0.modelClient = StubModelClient.echo
      $0.apiKeyStore = .testValue  // no key → frontier unavailable
    } operation: {
      let model = ChatModel(context: ideaContext, tools: recorder)
      #expect(model.frontierAvailable == false)
      #expect(model.sendsToProvider == false)
      await model.send("Is this place vegetarian-friendly?")
      #expect(model.messages.count == 2)
      #expect(model.messages.last?.role == .assistant)
      #expect(model.messages.last?.text == "Is this place vegetarian-friendly?")
      #expect(recorder.calls.withLock { $0 }.isEmpty)  // no tool use on-device
      #expect(model.errorText == nil)
    }
  }

  @Test("frontier path runs the tool loop: tool_use → run verb → tool_result → final text")
  func frontierToolLoop() async {
    let recorder = ToolRecorder(result: "Found 1 idea: Noma — Food.")
    await withDependencies {
      $0.apiKeyStore = .testValue
      $0.apiKeyStore.setKey("sk-ant-test", for: .anthropic)
      // First model turn asks for a tool; once a tool_result is present, it answers.
      $0.modelClient = TieredModelClient(
        onDevice: StubModelClient.echo, frontier: scriptedToolModel())
    } operation: {
      let model = ChatModel(context: ChatContext.pool(PoolContext(lens: "All", ideas: [])),
        tools: recorder)
      model.useFrontier = true
      #expect(model.frontierAvailable)
      #expect(model.sendsToProvider)
      await model.send("Which Denmark food ideas haven't we visited?")

      // The verb actually ran, with the model's parsed input.
      let calls = recorder.calls.withLock { $0 }
      #expect(calls.count == 1)
      #expect(calls.first?.name == "query_pool")
      #expect(calls.first?.input.string("query") == "denmark food")
      // The assistant's final, post-tool answer is shown.
      #expect(model.messages.last?.role == .assistant)
      #expect(model.messages.last?.text.contains("Noma") == true)
      #expect(model.errorText == nil)
    }
  }

  @Test("a frontier createIdea call is dispatched to the executor")
  func frontierCreateIdea() async {
    let recorder = ToolRecorder(result: "Added \"Alchemist\" to the pool as a candidate.")
    await withDependencies {
      $0.apiKeyStore = .testValue
      $0.apiKeyStore.setKey("sk-ant-test", for: .anthropic)
      $0.modelClient = TieredModelClient(
        onDevice: StubModelClient.echo,
        frontier: scriptedToolModel(
          tool: "create_idea", input: ["name": "Alchemist"], answer: "Added it as a candidate."))
    } operation: {
      let model = ChatModel(context: ideaContext, tools: recorder)
      model.useFrontier = true
      await model.send("Add Alchemist to the pool")
      let calls = recorder.calls.withLock { $0 }
      #expect(calls.first?.name == "create_idea")
      #expect(calls.first?.input.string("name") == "Alchemist")
      #expect(model.messages.last?.text.contains("candidate") == true)
    }
  }

  @Test("custom chat instructions are appended to the system prompt")
  func customInstructionsInSystemPrompt() {
    withDependencies {
      $0.apiKeyStore = .testValue
      $0.chatInstructions = ChatInstructions { "Always include a booking link." }
    } operation: {
      let prompt = ChatModel(context: ideaContext, tools: ToolRecorder()).systemPrompt()
      #expect(prompt.contains("Always include a booking link."))
      #expect(prompt.contains("standing instructions"))
    }
  }

  @Test("empty instructions leave the system prompt at its base")
  func emptyInstructionsOmitted() {
    withDependencies {
      $0.apiKeyStore = .testValue
      $0.chatInstructions = ChatInstructions { "   " }
    } operation: {
      let prompt = ChatModel(context: ideaContext, tools: ToolRecorder()).systemPrompt()
      #expect(!prompt.contains("standing instructions"))
    }
  }

  @Test("frontier chat enables server-side web search; on-device does not")
  func frontierEnablesWebSearch() async {
    let captured = Mutex<Int?>(nil)
    await withDependencies {
      $0.apiKeyStore = .testValue
      $0.apiKeyStore.setKey("sk-ant-test", for: .anthropic)
      $0.modelClient = TieredModelClient(
        onDevice: StubModelClient.echo,
        frontier: StubModelClient { request in
          captured.withLock { $0 = request.webSearchMaxUses }
          return ModelResponse(text: "ok", stopReason: "end_turn")
        })
    } operation: {
      let model = ChatModel(context: ideaContext, tools: ToolRecorder())
      model.useFrontier = true
      await model.send("What's a good coffee spot near here?")
      #expect(captured.withLock { $0 } == 5)  // web search on for the frontier turn
    }
  }

  @Test("blank input is ignored")
  func blankInputIgnored() async {
    await withDependencies {
      $0.modelClient = StubModelClient.echo
      $0.apiKeyStore = .testValue
    } operation: {
      let model = ChatModel(context: ideaContext, tools: ToolRecorder())
      await model.send("   ")
      #expect(model.messages.isEmpty)
    }
  }

  // MARK: - Stubs

  /// A frontier backend that asks for one tool on the first turn (no tool_result
  /// in history yet), then answers once the result comes back.
  private func scriptedToolModel(
    tool: String = "query_pool",
    input: JSONValue = ["query": "denmark food"],
    answer: String = "Found 1 idea: Noma — Food."
  ) -> StubModelClient {
    StubModelClient { request in
      let sawToolResult = request.messages.contains { message in
        message.content.contains { if case .toolResult = $0 { true } else { false } }
      }
      if sawToolResult {
        return ModelResponse(text: answer, stopReason: "end_turn")
      }
      return ModelResponse(
        text: "",
        toolCalls: [ModelToolCall(id: "toolu_1", name: tool, input: input)],
        stopReason: "tool_use")
    }
  }
}

/// Records the tool calls the loop dispatches and returns a canned result —
/// proves dispatch wiring without a database.
private final class ToolRecorder: ChatToolExecutor {
  let calls = Mutex<[ModelToolCall]>([])
  let result: String

  init(result: String = "ok") { self.result = result }

  func tools() -> [ModelTool] { ChatVerb.allCases.map(\.tool) }

  func run(_ call: ModelToolCall) async -> String {
    calls.withLock { $0.append(call) }
    return result
  }
}
