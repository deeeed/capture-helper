class CaptureHelper < Formula
  desc "Generic macOS ScreenCaptureKit CLI for window capture and agent evidence"
  homepage "https://github.com/deeeed/capture-helper"
  url "https://github.com/deeeed/capture-helper/releases/download/v0.1.5/capture-helper-darwin-arm64"
  version "0.1.5"
  sha256 "4e5d6e9e011858bf41f4c3f1e6740698d4f4c7c10ef4ce1a778427a35510caa0"
  license "MIT"

  depends_on :macos

  def install
    bin.install "capture-helper-darwin-arm64" => "capture-helper"
  end

  test do
    output = shell_output("#{bin}/capture-helper version")
    assert_match '"version"', output
    assert_match '"0.1.5"', output
  end
end
