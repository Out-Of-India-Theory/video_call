#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint oit_video_call.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'oit_video_call'
  s.version          = '1.0.0'
  s.summary          = 'OIT shared Flutter plugin wrapping Stream Video for Dharmayana apps.'
  s.description      = <<-DESC
OIT shared Flutter plugin wrapping Stream Video for Dharmayana apps.
                       DESC
  s.homepage         = 'https://github.com/Out-Of-India-Theory/video_call'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Out of India Theory' => 'engineering@the-oit.in' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'oit_video_call_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
