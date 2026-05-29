class CaptureHelper < Formula
  desc "Generic macOS ScreenCaptureKit CLI for window capture and agent evidence"
  homepage "https://github.com/deeeed/capture-helper"
  url "https://github.com/deeeed/capture-helper/releases/download/v0.1.4/capture-helper-darwin-arm64"
  version "0.1.4"
  sha256 "c64431f80b8b7a0a6e7f7b25530ea1b92a49e1c6ce1bda1609d43c7776dfe607"
  license "MIT"

  depends_on :macos

  def install
    bin.install "capture-helper-darwin-arm64" => "capture-helper"
  end

  test do
    output = shell_output("#{bin}/capture-helper version")
    assert_match '"version"', output
    assert_match '"0.1.4"', output
  end
end
