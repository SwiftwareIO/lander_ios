Pod::Spec.new do |s|
  s.name             = 'LanderSDK'
  s.version          = '0.1.0'
  s.summary          = 'Deep linking without the fuss: the native iOS SDK for Lander.'
  s.description      = <<~DESC
    Receive Universal Links and custom scheme URLs, resolve them to the links you created in
    Lander, recover deferred links after install, create short links from inside the app and
    report conversions with an offline event queue.
  DESC
  s.homepage         = 'https://golander.link/docs/ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Lander' => 'team@golander.link' }
  s.source           = { :git => 'https://github.com/SwiftwareIO/lander_ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['6.0']

  # `import Lander`, the same module name as the Swift package.
  s.module_name      = 'Lander'
  s.source_files     = 'Sources/Lander/**/*.swift'
  s.resource_bundles = { 'Lander_Privacy' => ['Sources/Lander/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UIKit', 'CryptoKit'
end
