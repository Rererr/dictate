import Foundation
import Testing
@testable import SpeechCore

@Suite struct LiveTranscriberTests {
    /// キーを一瞬だけ押して離すと、音声が 1 つも届かないまま入力が終わる。
    /// 認識モデルが未導入の環境では start が失敗するが、それも「待ち続けない」の範囲である。
    @Test(.timeLimit(.minutes(1))) func 音声が届かずに入力が終わっても結果の待ちが終わる() async {
        let (input, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation.finish()
        await #expect(throws: SpeechCoreError.self) {
            for try await _ in try await LiveTranscriber().start(input: input) {}
        }
    }
}

@Suite struct 認識モデルの有無 {
    /// 起動時の案内とメニューの表示が、この判定に依る。存在しないロケールは、どの Mac でも未導入である。
    @Test func 存在しないロケールは未導入と判定する() async {
        #expect(await LiveTranscriber(locale: Locale(identifier: "xx-XX")).isModelInstalled() == false)
    }
}
