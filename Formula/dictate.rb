# Homebrew の formula。このリポジトリ自体を tap として登録すると、clone せずに組んで入れられる。
#   brew tap rererr/dictate https://github.com/Rererr/dictate
#   brew install --HEAD rererr/dictate/dictate
# Homebrew が Command Line Tools を要求するので、Swift は揃っている。
class Dictate < Formula
  desc "Push-to-talk Japanese dictation, on-device with Apple SpeechTranscriber"
  homepage "https://github.com/Rererr/dictate"
  license "MIT"
  head "https://github.com/Rererr/dictate.git", branch: "main"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    # Homebrew のサンドボックスの中では SwiftPM 自身のサンドボックスが動かない
    system "swift", "build", "-c", "release", "--disable-sandbox"
    # アドホック署名。キーチェーンはサンドボックスから触らない
    system "scripts/bundle.sh", "--no-build", "-"
    prefix.install "build/Dictate.app"
    (bin/"dictate").write <<~SH
      #!/bin/sh
      exec open -a "#{opt_prefix}/Dictate.app" --args "$@"
    SH
  end

  def caveats
    <<~EOS
      起動: dictate（または open #{opt_prefix}/Dictate.app）
      Spotlight や Launchpad から起動したいときは、~/Applications に写す:
        ditto #{opt_prefix}/Dictate.app ~/Applications/Dictate.app

      初回は、マイクとアクセシビリティの許可と、日本語の音声認識モデルが要る。
      メニューバーのマイクのアイコンを開くと、三つの状態と、足りないものの設定を開く項目が出る。

      更新: brew upgrade --fetch-HEAD dictate（--fetch-HEAD が無いと HEAD の formula は更新されない）
      アドホック署名のため、更新のたびにアクセシビリティの許可を付け直す必要がある。
      一覧でオンに見えるのに入らないときは、メニューの「アクセシビリティの許可を付け直す」を選ぶ。
    EOS
  end

  test do
    system "codesign", "--verify", "--strict", prefix/"Dictate.app"
  end
end
