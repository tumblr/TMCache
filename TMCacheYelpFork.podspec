Pod::Spec.new do |s|
  s.name          = 'TMCacheYelpFork'
  s.version       = '1.2.1'
  s.source_files  = 'TMCache/*.{h,m}'
  s.homepage      = 'https://github.com/Yelp/TMCache'
  s.summary       = 'Fast parallel object cache for iOS and OS X. Yelp fork.'
  s.authors       = { 'Justin Ouellette' => 'jstn@tumblr.com' }
  s.source        = { :git => 'https://github.com/Yelp/TMCache.git', :tag => "v#{s.version}" }
  s.license       = { :type => 'Apache 2.0', :file => 'LICENSE.txt' }
  s.header_dir    = 'TMCache'
  s.requires_arc  = true
  s.frameworks    = 'Foundation'
  s.ios.weak_frameworks   = 'UIKit'
  s.osx.weak_frameworks   = 'AppKit'
  s.ios.deployment_target = '5.0'
  s.osx.deployment_target = '10.7'
  s.documentation = {
    :html => 'http://cocoadocs.org/docsets/TMCache/',
    :appledoc => [
      '--company-id', 'com.tumblr',
      '--project-name', 'TMCache',
      '--project-company', 'Tumblr',
      '--project-version', '1.2.0',
      '--docset-min-xcode-version', '4.3',
      '--docset-bundle-name', '%PROJECT %VERSION',
      '--docset-bundle-id', '%COMPANYID.%PROJECTID',
      '--docset-bundle-filename', '%COMPANYID.%PROJECTID-%VERSIONID.docset',
      '--ignore', 'tests',
      '--ignore', 'docs',
      '--ignore', '*.m',
      '--no-repeat-first-par',
      '--explicit-crossref',
      '--clean-output'
    ]
  }
end
