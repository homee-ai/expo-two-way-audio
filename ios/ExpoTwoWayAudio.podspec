require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoTwoWayAudio'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = { :ios => '13.4', :tvos => '13.4' }
  s.swift_version  = '5.4'
  s.source         = { git: 'https://github.com/speechmatics/expo-two-way-audio' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility + import path for the vendored aic-sdk C module
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'SWIFT_INCLUDE_PATHS' => '"$(PODS_TARGET_SRCROOT)/Vendored/include"'
  }

  # ai-coustics Quail SDK (https://github.com/ai-coustics/aic-sdk-c), vendored by
  # scripts/vendor-aic-sdk.sh. Static lib; Swift imports it as `AicSdk` via the
  # modulemap in Vendored/include.
  s.vendored_frameworks = 'Vendored/aic.xcframework'
  s.preserve_paths = 'Vendored/**/*'
  s.exclude_files = 'Vendored/**/*'
  s.resource_bundles = { 'AicModels' => ['Vendored/Models/*.aicmodel'] }

  s.source_files = "**/*.{h,m,swift}"
end
