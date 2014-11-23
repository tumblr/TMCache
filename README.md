# TMCache #

## Fast parallel object cache for iOS and OS X. ##

[TMCache](TMCache/TMCache.h) is a key/value store designed for persisting temporary objects that are expensive to reproduce, such as downloaded data or the results of slow processing. It is comprised of two self-similar stores, one in memory ([TMMemoryCache](TMCache/TMMemoryCache.h)) and one on disk ([TMDiskCache](TMCache/TMDiskCache.h)), all backed by GCD and safe to access from multiple threads simultaneously. On iOS, `TMMemoryCache` will clear itself when the app receives a memory warning or goes into the background. Objects stored in `TMDiskCache` remain until you trim the cache yourself, either manually or by setting a byte or age limit.

`TMCache` and `TMDiskCache` accept any object conforming to [NSCoding](https://developer.apple.com/library/ios/#documentation/Cocoa/Reference/Foundation/Protocols/NSCoding_Protocol/Reference/Reference.html). Put things in like this:

```objective-c
UIImage *img = [[UIImage alloc] initWithData:data scale:[[UIScreen mainScreen] scale]];
[[TMCache sharedCache] setObject:img forKey:@"image" block:nil]; // returns immediately
```
    
Get them back out like this:

```objective-c
[[TMCache sharedCache] objectForKey:@"image"
                              block:^(TMCache *cache, NSString *key, id object) {
                                  UIImage *image = (UIImage *)object;
                                  NSLog(@"image scale: %f", image.scale);
                              }];
```
                                  
`TMMemoryCache` allows for concurrent reads and serialized writes, while `TMDiskCache` serializes disk access across all instances in the app to increase performance and prevent file contention. `TMCache` coordinates them so that objects added to memory are available immediately to other threads while being written to disk safely in the background. Both caches are public properties of `TMCache`, so it's easy to manipulate one or the other separately if necessary.

Collections work too. Thanks to the magic of `NSKeyedArchiver`, objects repeated in a collection only occupy the space of one on disk:

```objective-c
NSArray *images = @[ image, image, image ];
[[TMCache sharedCache] setObject:images forKey:@"images"];
NSLog(@"3 for the price of 1: %d", [[[TMCache sharedCache] diskCache] byteCount]);
```

## Installation  ##

### Manually ####

[Download the latest tag](https://github.com/tumblr/TMCache/tags) and drag the `TMCache` folder into your Xcode project.

Install the docs by double clicking the `.docset` file under `docs/`, or view them online at [cocoadocs.org](http://cocoadocs.org/docsets/TMCache/)

### Git Submodule ###

    git submodule add https://github.com/tumblr/TMCache.git
    git submodule update --init

### CocoaPods ###

Add [TMCache](http://cocoapods.org/?q=name%3ATMCache) to your `Podfile` and run `pod install`.

## Build Status ##

[![Build Status](https://travis-ci.org/tumblr/TMCache.png?branch=master)](https://travis-ci.org/tumblr/TMCache)

## Requirements ##

__TMCache__ requires iOS 7.0 or OS X 10.7 and greater.

## Contact ##

[Bryan Irace](mailto:bryan@tumblr.com)

## License ##

Copyright 2013 Tumblr, Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. [See the License](LICENSE.txt) for the specific language governing permissions and limitations under the License.
