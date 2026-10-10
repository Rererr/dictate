import AppKit

// --demo: マイクも認識も使わず、字幕とトーストをメニューから再生する。
// --demo --play N: 起動の直後に N 番目（0 始まり）の場面を再生する。--open-menu: 起動の直後にメニューを開く（通常の起動でも効く）。
// どちらも画面の確認（スクリーンショット）のためで、人が操作するなら要らない。
let arguments = CommandLine.arguments
let play = arguments.firstIndex(of: "--play").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
let controller = AppController(demo: arguments.contains("--demo"), autoplay: play, openMenu: arguments.contains("--open-menu"))
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
