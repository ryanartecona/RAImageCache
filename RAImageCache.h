//
//  RAImageCache.h
//  Flickr Maps
//
//  Created by Ryan Artecona on 10/2/12.
//  Copyright (c) 2012 Ryan Artecona. All rights reserved.
//

#import <Foundation/Foundation.h>


#define RACacheTimeout1Day          86400.0
#define RACacheTimeout1Week         604800.0
#define RACacheTimeout1Month        18144000.0
#define RACacheTimeoutIndefinite    0.0
#define RACacheTimeoutDefault       RACacheTimeout1Month


@interface RAImageCache : NSObject

+(RAImageCache *) sharedCache;

// reading from cache
-(UIImage *) imageWithDefaultTimeoutFromUrl:(NSURL *)fromURL;
-(UIImage *) imageFromURL:(NSURL *)fromURL withTimeout:(NSTimeInterval)timeout;

// saving to cache
-(void) cacheImage:(UIImage *)image withKey:(NSString *)key timeout:(NSTimeInterval)timeout;
-(void) cacheImage:(UIImage *)image withKeyURL:(NSURL *)keyURL timeout:(NSTimeInterval)timeout;
-(void) invalidateImageWithKey:(NSString *)key;
-(void) invalidateImageWithKeyURL:(NSURL *)keyURL;

// cache maintenance
-(void) synchronize;
-(void) flushAllItems;

@end
