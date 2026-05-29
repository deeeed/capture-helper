class CaptureHelper < Formula
  desc "Generic macOS ScreenCaptureKit CLI for window capture and agent evidence"
  homepage "https://github.com/deeeed/capture-helper"
  url "https://github.com/deeeed/capture-helper/releases/download/v0.1.3/capture-helper-darwin-arm64"
  version "0.1.3"
  sha256 "8828729d22f26edcfc9a63b69b4b43676623336ebf3c0b27a5cc91a9c71402b5"
  license "MIT"

  depends_on :macos

  def install
    bin.install "capture-helper-darwin-arm64" => "capture-helper"
  end

  test do
    output = shell_output("#{bin}/capture-helper version")
    assert_match '"version"', output
    assert_match '"0.1.3"', output
  end
end
