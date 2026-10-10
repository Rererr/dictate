import AppKit

// --demo: マイクも認識も使わず、字幕とトーストをメニューから再生する。
// --demo --play N: 起動の直後に N 番目（0 始まり）の場面を再生する。--open-menu [秒]: 起動から（既定 1 秒）後にメニューを開く（通常の起動でも効く）。
// どちらも画面の確認（スクリーンショット）のためで、人が操作するなら要らない。
let arguments = CommandLine.arguments
let play = arguments.firstIndex(of: "--play").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
// --open-menu の次に秒数があれば、その秒数だけ待ってから開く（起動後の状態の変化を見るとき）
let openMenuAfter: Double? = arguments.firstIndex(of: "--open-menu").map { index in
    arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 1 : 1
}
// --select "項目名" [秒]: 起動から（既定 1 秒）後に、メニューのその項目を選ぶ（クリックと同じ処理を呼ぶ。復帰の経路の確認用）
let select: (title: String, after: Double)? = arguments.firstIndex(of: "--select").flatMap { index in
    guard arguments.indices.contains(index + 1) else { return nil }
    let after = arguments.indices.contains(index + 2) ? Double(arguments[index + 2]) ?? 1 : 1
    return (arguments[index + 1], after)
}
let controller = AppController(demo: arguments.contains("--demo"), autoplay: play, openMenuAfter: openMenuAfter, select: select)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()
