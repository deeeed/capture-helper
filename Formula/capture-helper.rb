class CaptureHelper < Formula
  desc "Generic macOS ScreenCaptureKit CLI for window capture and agent evidence"
  homepage "https://github.com/deeeed/capture-helper"
  url "https://github.com/deeeed/capture-helper/releases/download/v0.1.7/capture-helper-darwin-arm64"
  version "0.1.7"
  sha256 "eb69c61d6abedce79ce6cf8c66e5730d9be08a18fecc4698aa3c5996db7611df"
  license "MIT"

  depends_on :macos

  def install
    bin.install "capture-helper-darwin-arm64" => "capture-helper"
  end

  test do
    output = shell_output("#{bin}/capture-helper version")
    assert_match '"version"', output
    assert_match '"0.1.7"', output
  end
end
