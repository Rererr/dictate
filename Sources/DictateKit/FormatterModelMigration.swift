import Foundation

/// 以前の既定の組（v0.2.0 までの Qwen3-4B のモデルと、それを立てる既定の起動コマンド）のままの設定を、今の既定の組へ一度だけ移す（ADR-15）。
/// 本人が変えた設定（モデルか起動コマンドが違う、起動しない、この Mac 以外の接続先、8B の組）には触らない。
public enum FormatterModelMigration {
    public static let legacyModel = "mlx-community/Qwen3-4B-4bit"
    /// 確かめたことの印。設定と同じ場所に置く（設定を消せば印も消え、DICTATE_HOME で隔離した設定には隔離した印が付く）
    public static let markerName = "formatter-model-migrated-from-qwen3-4b.txt"
    static let markerText = "Dictate が、整形のモデルを以前の既定（mlx-community/Qwen3-4B-4bit）から今の既定へ移すかを確かめた印です。\nこのファイルがある間は確かめません（Qwen3-4B に戻した設定を書き換え直さないため）。消すと、次の起動で確かめ直します。\n"

    /// 移したら、移した後の整形の設定を返す（知らせの文面を、整形を使っているかで分けるため）。移さなければ nil。
    /// 印があれば何もしない。設定ファイルが無ければ、移すものが無いので印も付けない（設定の場所を作らない）。
    /// 読めない設定は投げて書き換えず、書き戻せないときも投げる。どちらも印を付けないので、次の起動で確かめ直す
    public static func run(config url: URL) throws -> Config.Formatter? {
        let marker = url.deletingLastPathComponent().appending(path: markerName)
        guard !FileManager.default.fileExists(atPath: marker.path), FileManager.default.fileExists(atPath: url.path) else { return nil }
        var formatter = try Config.load(from: url).formatter
        let migrates = formatter.usesDefaultServer && formatter.model == legacyModel
        if migrates {
            formatter.model = Config.Formatter.smallModel
            formatter.startCommand = Config.Formatter.defaultStartCommand(model: Config.Formatter.smallModel)
            try Config.update(at: url) { [formatter] in $0.formatter = formatter }
        }
        try Data(markerText.utf8).write(to: marker, options: .atomic)
        return migrates ? formatter : nil
    }
}
