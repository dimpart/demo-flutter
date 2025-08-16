#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint dim_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'dim_flutter'
  s.version          = '1.0.0'
  s.summary          = 'DIM Client'
  s.description      = <<-DESC
DIM Client
                       DESC
  s.homepage         = 'https://github.com/dimpart/demo-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Albert Moky' => 'albert.moky@gmail.com' }
  s.social_media_url = "https://twitter.com/AlbertMoky"
  s.source           = { :git => 'https://github.com/dimpart/demo-flutter.git', :tag => s.version.to_s }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
