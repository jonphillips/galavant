import ChatAccessKit
import Darwin
import Foundation
import GalavantMCPServer
import MCPServerKit

@main
enum GalavantMCP {
  static func main() async {
    ChatAccessHelperProcess.enableDatalessMaterialization()
    do {
      let isDevelopment = try ChatAccessHelperFolder.isDevelopment(arguments: CommandLine.arguments)
      await GalavantMCPServer.make(isDevelopment: isDevelopment).run()
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(EXIT_FAILURE)
    }
  }
}
