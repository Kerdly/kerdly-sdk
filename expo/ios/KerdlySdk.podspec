require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The native KerdlySDK sources are vendored here by scripts/sync-native.mjs (npm `prepare`/`prepack`)
# from ../ios/Sources/KerdlySDK. CocoaPods cannot compile files outside the pod directory, so a
# missing copy is a broken install: fail now with the fix instead of with "cannot find 'Kerdly'".
vendored_sdk = File.join(__dir__, 'KerdlySDK')
if Dir.glob(File.join(vendored_sdk, '**', '*.swift')).empty?
  raise "[@kerdly/expo] #{vendored_sdk} is missing. Run `npm run sync-native` in the @kerdly/expo " \
        'package (it copies ../ios/Sources/KerdlySDK), or install a packed/published build of the package.'
end

Pod::Spec.new do |s|
  s.name           = 'KerdlySdk'
  s.version        = package['version']
  s.summary        = 'Expo bridge for the Kerdly attribution SDK (vendored KerdlySDK)'
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/Kerdly/kerdly-sdk.git', tag: package['version'] }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # The bridge and the vendored SDK compile into this one module, so KerdlySdkModule.swift calls `Kerdly`
  # without `import KerdlySDK`.
  s.source_files = '*.swift', 'KerdlySDK/**/*.swift'

  # The SDK's privacy manifest (required-reason APIs, tracking domains), as a resource bundle so
  # Xcode aggregates it into the app's privacy report.
  s.resource_bundles = { 'KerdlySDKPrivacy' => ['KerdlySDK/**/PrivacyInfo.xcprivacy'] }

  # The SDK imports AdAttributionKit (iOS 17.4+) behind availability checks; weak-link it so the app
  # still launches on older iOS versions.
  s.weak_frameworks = 'AdAttributionKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
