//
//  RAImageCache.m
//  Flickr Maps
//
//  Created by Ryan Artecona on 10/2/12.
//  Copyright (c) 2012 Ryan Artecona. All rights reserved.
//

#import "RAImageCache.h"
#import <CommonCrypto/CommonDigest.h>


#define CACHE_DIRECTORY			@"_RAImageCache"
#define INDEX_FILENAME			@"cache_index.plist"
#define CACHE_MAX_ITEMS			1000
#define CACHE_MAX_SIZE			10485760 // 10mb
#define CACHE_PRUNE_INTERVAL	60.0 // 1min

#define INDEX_ITEM_KEY_KEY			@"key"
#define INDEX_ITEM_KEY_TIMEOUT		@"timeout"
#define INDEX_ITEM_KEY_LAST_TOUCHED	@"last_touched"
#define INDEX_ITEM_KEY_SIZE			@"size"


@interface RAImageCache ()

// URL for the directory where we store all out cache files
@property (nonatomic, strong) NSURL *cacheDirectory;

// mutable dict that holds metadata for all our cache items
@property (nonatomic, strong) NSMutableDictionary *index;

// keep track of the total size of the cache (in bytes, excluding index file)
@property (nonatomic, assign) NSInteger totalSize;

// keep track of when we prune the cache, so we don't do it unnecessarily often
@property (nonatomic, strong) NSDate *dateLastPruned;

// do all reads/writes on a single queue
// (allow concurrent reads, and make writes block all async reads)
@property (nonatomic, assign) dispatch_queue_t ioQueue;

// queue on which we do queue maintenance (flushing, storage mgmt, etc.)
@property (nonatomic, assign) dispatch_queue_t backgroundQueue;

@end


@implementation RAImageCache

// global var for singleton instance
static RAImageCache *sharedCache = nil;

@synthesize cacheDirectory = _cacheDirectory;
@synthesize index = _index;
@synthesize ioQueue = _ioQueue;
@synthesize backgroundQueue = _backgroundQueue;

-(NSMutableDictionary *) index //lazy instantiate
{
    if (!_index) {
        NSURL *indexURL = [self.cacheDirectory URLByAppendingPathComponent:INDEX_FILENAME];
        _index = [NSMutableDictionary dictionaryWithContentsOfURL:indexURL];
        if (!_index) _index = [NSMutableDictionary dictionary];
    }
    return _index;
}

-(id) init
{
    if ((self = [super init]))
	{
        self.cacheDirectory = [RAImageCache directoryForSharedCache];
		// we want reads to happen concurrently,
		// and writes to happen on the same queue (but block reads)
		self.ioQueue = dispatch_queue_create("com.RyanArtecona.RAImageCache.ioQueue", DISPATCH_QUEUE_CONCURRENT);
		// we want maintenance to happen on a serial background queue
        self.backgroundQueue = dispatch_queue_create("com.RyanArtecona.RAImageCache.backgroundQueue", DISPATCH_QUEUE_SERIAL);
		dispatch_set_target_queue(self.backgroundQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
		
		// we need to figure out how big the cache is
		self.totalSize = 0;
		for (NSDictionary *indexItem in [self.index objectEnumerator]) {
			self.totalSize += [[indexItem objectForKey:INDEX_ITEM_KEY_SIZE] integerValue];
		}
		
		// on init, we want to clean out the cache
		self.dateLastPruned = [NSDate dateWithTimeIntervalSince1970:0];
		[self prune];
    }
    return self;
}

-(UIImage *) imageWithDefaultTimeoutFromUrl:(NSURL *)fromURL
{
	return [self imageFromURL:fromURL withTimeout:RACacheTimeoutDefault];
}

-(UIImage *) imageFromURL:(NSURL *)fromURL withTimeout:(NSTimeInterval)timeout
{
	NSString *key = [fromURL absoluteString];
	__block UIImage *image;
	dispatch_sync(self.ioQueue, ^{
		image = [self getCachedImageWithKey:key];
	});
	// if we have a cached version of this image,
	// touch it (reset its timeout) and return it
	if (image) {
		dispatch_barrier_async(self.ioQueue, ^{
			[self touchImageWithKey:key timeout:timeout];
		});
		return image;
	}
	// else, fetch the image, cache it, and return it
	else {
		NSData *imageData = [NSData dataWithContentsOfURL:fromURL];
		UIImage *image = [UIImage imageWithData:imageData];
		dispatch_barrier_async(self.ioQueue, ^{
			[self cacheImage:image withKey:key timeout:timeout];
		});
		return image;
	}
}

-(void) cacheImage:(UIImage *)image withKeyURL:(NSURL *)keyURL timeout:(NSTimeInterval)timeout
{
	[self cacheImage:image withKey:[keyURL absoluteString] timeout:timeout];
}

-(void) cacheImage:(UIImage *)image withKey:(NSString *)key timeout:(NSTimeInterval)timeout
{
	dispatch_barrier_async(self.ioQueue, ^{
		
		// remove the previous item, if any
		[self removeCacheItemForKey:key];
		
		NSString *imageFilePath = [[self cacheFileURLForImageWithKey:key] path];
		NSData *imageData = UIImagePNGRepresentation(image);
		NSUInteger imageSizeInBytes = [imageData length];
		// finally, write to file
		[[NSFileManager defaultManager] createFileAtPath:imageFilePath contents:imageData attributes:nil];
		// and make the new index entry
		NSDictionary *newIndexItem = @{ INDEX_ITEM_KEY_KEY : key,
										INDEX_ITEM_KEY_TIMEOUT : [NSNumber numberWithUnsignedInteger:timeout],
										INDEX_ITEM_KEY_LAST_TOUCHED : [NSDate date],
										INDEX_ITEM_KEY_SIZE : [NSNumber numberWithUnsignedInteger:imageSizeInBytes] };
		self.totalSize += imageSizeInBytes;
		[self.index setObject:newIndexItem forKey:key];
		
		// and schedule a prune
		[self prune];
		
		// and make it persist
		[self synchronize];
	});
}

-(void) invalidateImageWithKeyURL:(NSURL *)keyURL
{
	[self invalidateImageWithKey:[keyURL absoluteString]];
}

-(void) invalidateImageWithKey:(NSString *)key
{
	dispatch_barrier_async(self.ioQueue, ^{
		[self removeCacheItemForKey:key];
	});
}

-(void) synchronize
{
	dispatch_barrier_async(self.ioQueue, ^{
		NSURL *indexURL = [self.cacheDirectory URLByAppendingPathComponent:INDEX_FILENAME];
		[self.index writeToFile:[indexURL path] atomically:YES];
	});
}

-(void) flushAllItems
{
	dispatch_async(self.backgroundQueue, ^{
		
		dispatch_barrier_async(self.ioQueue, ^{
		
			for (NSString *key in self.index) {
				NSURL *imageURL = [self cacheFileURLForImageWithKey:key];
				[[NSFileManager defaultManager] removeItemAtURL:imageURL error:nil];
			}
			NSURL *indexFileURL = [self.cacheDirectory URLByAppendingPathComponent:INDEX_FILENAME];
			[[NSFileManager defaultManager] removeItemAtURL:indexFileURL error:nil];
			self.index = nil;
			self.totalSize = 0;
		});
	});
}

-(void) prune
{
	// we only schedule a prune if the prune_interval has passed
	// since we last pruned
	NSDate *datePruneNextNeeded = [NSDate dateWithTimeInterval:CACHE_PRUNE_INTERVAL sinceDate:self.dateLastPruned];
	NSDate *now = [NSDate date];
	if (([datePruneNextNeeded laterDate:now] == now) &&
		(([self.index count] > CACHE_MAX_ITEMS) ||
		 (self.totalSize > CACHE_MAX_SIZE))) {
		// we want prune to get queued to the background
		dispatch_async(self.backgroundQueue, ^{
			// but actually do the work on the I/O queue
			dispatch_barrier_sync(self.ioQueue, ^{
				
				// order all the cache items by the time they were last touched (descending (most recent first))
				NSMutableArray *indexKeysToKeep = [[self.index keysSortedByValueUsingComparator:^NSComparisonResult (id a, id b){
					NSDate *dateA = [a objectForKey:INDEX_ITEM_KEY_LAST_TOUCHED];
					NSDate *dateB = [b objectForKey:INDEX_ITEM_KEY_LAST_TOUCHED];
					return [dateB compare:dateA];
				}] mutableCopy];
				
				// pop the last (oldest touched) key off of indexKeys
				// until the cache reaches the item count & size quotas
				NSUInteger itemCount = [self.index count];
				while ((itemCount > CACHE_MAX_ITEMS) || (self.totalSize > CACHE_MAX_SIZE)) {
					NSString *lastKey = [indexKeysToKeep lastObject];
					[self removeCacheItemForKey:lastKey];
					[indexKeysToKeep removeLastObject];
					itemCount -= 1;
				};
				
				// with pruning done, mutableIndexKeys contains all
				// the index items we want to keep
				self.index = [[self.index dictionaryWithValuesForKeys:indexKeysToKeep] mutableCopy];
			});
		});
		self.dateLastPruned = now;
	}
}

#pragma mark - Instance Helper methods 

-(UIImage *) getCachedImageWithKey:(NSString *)key
{
	NSDictionary *indexItem = [self.index objectForKey:key];
	if (indexItem) {
		// we have an index entry for this key
		if (![self itemIsExpired:indexItem]) {
			// this item hasn't yet expired
			NSURL *imageFileURL = [self cacheFileURLForImageWithKey:key];
			NSString *imageFilePath = [imageFileURL path];
			BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:imageFilePath];
			if (fileExists) {
				// this cache item is valid, and its file exists
				NSData *imageData = [[NSFileManager defaultManager] contentsAtPath:imageFilePath];
				UIImage *image = [UIImage imageWithData:imageData];
				return image;
			}
			else {
				// this cached file must have been deleted
				return nil;
			}
		}
		else {
			// item has expired
			return nil;
		}
	}
	else {
		// we don't have an index entry for this key
		return nil;
	}
}

-(void) touchImageWithKey:(NSString *)key timeout:(NSTimeInterval)timeout
{
	NSMutableDictionary *indexItem = [[self.index objectForKey:key] mutableCopy];
	if (indexItem) {
		NSDate *now = [NSDate date];
		[indexItem setObject:now forKey:INDEX_ITEM_KEY_LAST_TOUCHED];
		NSNumber *timeoutNum = [NSNumber numberWithDouble:timeout];
		[indexItem setObject:timeoutNum forKey:INDEX_ITEM_KEY_TIMEOUT];
		
		[self.index setObject:indexItem forKey:key];
	}
}

-(BOOL) itemIsExpired:(NSDictionary *)indexItem
{
	NSDate *now = [NSDate date];
	NSDate *dateLastTouched = [indexItem objectForKey:INDEX_ITEM_KEY_LAST_TOUCHED];
	NSNumber *timeoutNum = [indexItem objectForKey:INDEX_ITEM_KEY_TIMEOUT];
	NSTimeInterval timeout = [timeoutNum doubleValue];
	// if timeout has been set, and is 0, it is a permanent cache item
	if (timeoutNum && timeout == 0) return NO;
	NSDate *expirationDate = [NSDate dateWithTimeInterval:timeout sinceDate:dateLastTouched];
	// return YES if item has expired, else NO
	return ([[now laterDate:expirationDate] isEqual:now]) ? YES : NO;
}

-(void) removeCacheItemForKey:(NSString *)key
{
	if ([key length]) {
		NSDictionary *indexItem = [self.index objectForKey:key];
		if (indexItem) {
			// remove file
			NSURL *cacheFileURL = [self cacheFileURLForImageWithKey:key];
			[[NSFileManager defaultManager] removeItemAtURL:cacheFileURL error:nil];
			// remove item from index
			self.totalSize -= [[indexItem objectForKey:INDEX_ITEM_KEY_SIZE] integerValue];
			[self.index removeObjectForKey:key];
		}
	}
}

-(NSURL *) cacheFileURLForImageWithKey:(NSString *)imageKey
{
	NSString *keyHash = [RAImageCache md5HashFromString:imageKey];
	return [self.cacheDirectory URLByAppendingPathComponent:keyHash];
}

#pragma mark - Class Helper methods

//+(NSString *) md5HashFromURL:(NSURL *)fromURL
//{
//	return [self md5HashFromString:[fromURL absoluteString]];
//}

+(NSString *) md5HashFromString:(NSString *)fromString
{
    //// The following MD5 algorithm from: http://mobiledevelopertips.com/core-services/create-md5-hash-from-nsstring-nsdata-or-file.html
    if (fromString)
	{
		// Create pointer to the string as UTF8
		const char *ptr = [fromString UTF8String];
		
		// Create byte array of unsigned chars
		unsigned char md5Buffer[CC_MD5_DIGEST_LENGTH];
		
		// Create 16 byte MD5 hash value, store in buffer
		CC_MD5(ptr, strlen(ptr), md5Buffer);
		
		// Convert MD5 value in the buffer to NSString of hex values
		NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
		for(int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
			[output appendFormat:@"%02x",md5Buffer[i]];
		
		return output;
	}
	else {
		return nil;
	}
}

+(NSURL *) directoryForSharedCache
{
    NSURL *baseDirectory = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *cacheDirectory = [baseDirectory URLByAppendingPathComponent:CACHE_DIRECTORY isDirectory:YES];
	[[NSFileManager defaultManager] createDirectoryAtPath:[cacheDirectory path] withIntermediateDirectories:YES attributes:nil error:nil];
    return cacheDirectory;
}

#pragma mark - Singleton methods and overrides

// return the singleton instance
+(RAImageCache *) sharedCache
{
    if (!sharedCache)
    {
        // prevent the singleton from trying to be
        // _created_ on multiple threads at once
        static dispatch_once_t pred;
        dispatch_once(&pred, ^{ // called at most once
            sharedCache = [[super allocWithZone:NULL] init];
        });
    }
    return sharedCache;
}

+(id) allocWithZone:(NSZone *)zone
{
    return [self sharedCache];
}

@end
