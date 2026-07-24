require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "SmoothClipView"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "16.4" }
  s.source       = { :git => "https://github.com/kbrattli/react-native-smooth-clip-view.git", :tag => "v#{s.version}" }
  s.source_files = "ios/*.{h,m,mm,swift,cpp}"
  s.private_header_files = "ios/*.h"

  install_modules_dependencies(s)

  s.test_spec "Tests" do |test_spec|
    test_spec.framework = "XCTest"
    test_spec.source_files = "ios/tests/**/*.{m,mm}"
  end
end
