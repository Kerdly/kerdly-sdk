Pod::Spec.new do |s|
  s.name          = 'KerdlySDK'
  s.version       = '0.1.0'
  s.summary       = 'Kerdly first-party attribution SDK for iOS (protocol v1).'
  s.description   = <<~DESC
    Install identity, launch and deep-link events, StoreKit purchase links, AppTransaction and Apple
    Ads token signals, ATT and consent, and the SKAdNetwork / AdAttributionKit writer, delivered to
    the Kerdly collector over protocol v1. The same sources as the Swift package.
  DESC
  s.homepage      = 'https://github.com/Kerdly/kerdly-sdk'
  s.license       = { :type => 'MIT', :file => 'LICENSE' }
  s.author        = 'Kerdly'
  s.source        = { :git => 'https://github.com/Kerdly/kerdly-sdk.git', :tag => s.version.to_s }

  s.platforms     = { :ios => '15.0' }
  s.swift_version = '5.9'

  s.source_files  = 'ios/Sources/KerdlySDK/**/*.swift'
  s.resource_bundles = { 'KerdlySDK_Privacy' => ['ios/Sources/KerdlySDK/Resources/PrivacyInfo.xcprivacy'] }

  s.frameworks      = 'Foundation', 'UIKit', 'Security', 'CryptoKit', 'StoreKit', 'AdServices', 'AdSupport',
                      'AppTrackingTransparency'
  # iOS 17.4+ only; every use is availability-guarded.
  s.weak_frameworks = 'AdAttributionKit'
end
