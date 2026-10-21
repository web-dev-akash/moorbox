# Homebrew formula for Moorbox. It builds the app from source on the user's Mac, so nothing
# has to bypass Gatekeeper (Homebrew no longer accepts unsigned casks).
#
# Published in the tap repository web-dev-akash/homebrew-moorbox as Formula/moorbox.rb:
#   brew install web-dev-akash/moorbox/moorbox
# The release workflow prints the url/sha256 values for each tagged version.
class Moorbox < Formula
  desc "Lightweight native macOS app for running Android virtual devices"
  homepage "https://github.com/web-dev-akash/moorbox"
  url "https://github.com/web-dev-akash/moorbox/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "REPLACED_BY_RELEASE_WORKFLOW"
  license "Apache-2.0"
  head "https://github.com/web-dev-akash/moorbox.git", branch: "main"

  depends_on "xcodegen" => :build
  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    ENV["MOORBOX_VERSION"] = build.head? ? File.read("VERSION").strip : version.to_s
    ENV["MOORBOX_BUILD"] = "1"
    system "xcodegen", "generate", "--quiet"
    xcodebuild "-project", "Moorbox.xcodeproj", "-scheme", "Moorbox", "-configuration", "Release",
               "-derivedDataPath", buildpath/"DerivedData", "-destination", "generic/platform=macOS",
               "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "build"
    app = buildpath/"DerivedData/Build/Products/Release/Moorbox.app"
    cp %w[LICENSE NOTICE THIRD_PARTY_NOTICES.md], app/"Contents/Resources"
    system "codesign", "--force", "--options", "runtime", "--sign", "-", app
    prefix.install app
  end

  def caveats
    <<~EOS
      Moorbox.app was built from source and installed to:
        #{opt_prefix}/Moorbox.app

      To find it in Launchpad and Spotlight, link it into your Applications folder:
        ln -sf "#{opt_prefix}/Moorbox.app" ~/Applications/Moorbox.app
    EOS
  end

  test do
    assert_predicate prefix/"Moorbox.app/Contents/MacOS/Moorbox", :executable?
    system "codesign", "--verify", "--strict", prefix/"Moorbox.app"
  end
end
