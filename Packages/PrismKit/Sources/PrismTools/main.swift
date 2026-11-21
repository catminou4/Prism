import AppKit
import Foundation

// Developer tools: `swift run prism-tools <command> [arguments]`.
// Commands are registered in ToolCommands.swift.
let arguments = Array(CommandLine.arguments.dropFirst())
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

guard let name = arguments.first, let command = ToolCommands.all.first(where: { $0.name == name }) else {
    print("usage: prism-tools <command> [arguments]\n")
    for command in ToolCommands.all {
        print("  \(command.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(command.summary)")
    }
    exit(arguments.isEmpty ? 0 : 1)
}
exit(command.run(Array(arguments.dropFirst())))
