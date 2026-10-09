import AppKit

let controller = AppController(demo: CommandLine.arguments.contains("--demo"))
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
