#import "TMDiskCache.h"

#define TMDiskCacheError(error) if (error) { NSLog(@"%@ (%d) ERROR: %@", \
                                    [[NSString stringWithUTF8String:__FILE__] lastPathComponent], \
                                    __LINE__, [error localizedDescription]); }

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
    #define TMCacheStartBackgroundTask() UIBackgroundTaskIdentifier taskID = UIBackgroundTaskInvalid; \
            taskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{ \
            [[UIApplication sharedApplication] endBackgroundTask:taskID]; }];
    #define TMCacheEndBackgroundTask() [[UIApplication sharedApplication] endBackgroundTask:taskID];
#else
    #define TMCacheStartBackgroundTask()
    #define TMCacheEndBackgroundTask()
#endif

NSString * const TMDiskCachePrefix = @"com.tumblr.TMDiskCache";
NSString * const TMDiskCacheSharedName = @"TMDiskCacheShared";
NSString * const TMDiskCacheStoreDatesName = @".TMDiskCacheStoreDates";

@interface TMDiskCache ()
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (strong, nonatomic) NSURL *storeDatesURL;
@property (assign, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) NSMutableDictionary *dates;
@property (strong, nonatomic) NSMutableDictionary *storeDates;
@property (strong, nonatomic) NSMutableDictionary *sizes;
@end

@implementation TMDiskCache

@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize byteLimit = _byteLimit;
@synthesize ageLimit = _ageLimit;

#pragma mark - Initialization -

- (instancetype)initWithName:(NSString *)name
{
    if (!name)
        return nil;

    if (self = [super init]) {
        _name = [name copy];
        _queue = [TMDiskCache sharedQueue];

        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;
        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;
        
        _byteCount = 0;
        _byteLimit = 0;
        _ageLimit = 0.0;

        _dates = [[NSMutableDictionary alloc] init];
        _storeDates = [[NSMutableDictionary alloc] init];
        _sizes = [[NSMutableDictionary alloc] init];

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@", TMDiskCachePrefix, _name];
        _cacheURL = [NSURL fileURLWithPathComponents:@[ [paths objectAtIndex:0], pathComponent ]];
        _storeDatesURL = [_cacheURL URLByAppendingPathComponent:TMDiskCacheStoreDatesName];

        __weak TMDiskCache *weakSelf = self;

        dispatch_async(_queue, ^{
            TMDiskCache *strongSelf = weakSelf;
            [strongSelf createCacheDirectory];
            [strongSelf initializeDiskProperties];
        });
    }
    return self;
}

- (NSString *)description
{
    return [[NSString alloc] initWithFormat:@"%@.%@.%p", TMDiskCachePrefix, _name, self];
}

+ (instancetype)sharedCache
{
    static id cache;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        cache = [[self alloc] initWithName:TMDiskCacheSharedName];
    });

    return cache;
}

+ (dispatch_queue_t)sharedQueue
{
    static dispatch_queue_t queue;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        queue = dispatch_queue_create([TMDiskCachePrefix UTF8String], DISPATCH_QUEUE_SERIAL);
    });

    return queue;
}

#pragma mark - Private Methods -

- (NSURL *)encodedFileURLForKey:(NSString *)key
{
    if (![key length])
        return nil;

    return [_cacheURL URLByAppendingPathComponent:[self encodedString:key]];
}

- (NSString *)keyForEncodedFileURL:(NSURL *)url
{
    NSString *fileName = [url lastPathComponent];
    if (!fileName)
        return nil;

    return [self decodedString:fileName];
}

- (NSString *)encodedString:(NSString *)string
{
    if (![string length])
        return @"";

    CFStringRef static const charsToEscape = CFSTR(".:/");
    CFStringRef escapedString = CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                                                        (__bridge CFStringRef)string,
                                                                        NULL,
                                                                        charsToEscape,
                                                                        kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)escapedString;
}

- (NSString *)decodedString:(NSString *)string
{
    if (![string length])
        return @"";

    CFStringRef unescapedString = CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault,
                                                                                          (__bridge CFStringRef)string,
                                                                                          CFSTR(""),
                                                                                          kCFStringEncodingUTF8);
    return (__bridge_transfer NSString *)unescapedString;
}

#pragma mark - Private Queue Methods -

- (BOOL)createCacheDirectory
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:[_cacheURL path]])
        return NO;

    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] createDirectoryAtURL:_cacheURL
                                            withIntermediateDirectories:YES
                                                             attributes:nil
                                                                  error:&error];
    TMDiskCacheError(error);

    return success;
}

- (void)initializeDiskProperties
{
    NSUInteger byteCount = 0;
    NSArray *keys = @[ NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey ];

    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:_cacheURL
                                                   includingPropertiesForKeys:keys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&error];
    TMDiskCacheError(error);

    NSMutableDictionary *storeDates = [NSKeyedUnarchiver unarchiveObjectWithFile:[_storeDatesURL path]];
    if (storeDates)
        _storeDates = storeDates;

    for (NSURL *fileURL in files) {
        NSString *key = [self keyForEncodedFileURL:fileURL];

        error = nil;
        NSDictionary *dictionary = [fileURL resourceValuesForKeys:keys error:&error];
        TMDiskCacheError(error);

        NSDate *date = [dictionary objectForKey:NSURLContentModificationDateKey];
        if (date)
            [_dates setObject:date forKey:key];

        NSNumber *fileSize = [dictionary objectForKey:NSURLTotalFileAllocatedSizeKey];
        if (fileSize) {
            [_sizes setObject:fileSize forKey:key];
            byteCount += [fileSize unsignedIntegerValue];
        }
    }

    if (byteCount > 0)
        self.byteCount = byteCount; // atomic
}

- (BOOL)setFileModificationDate:(NSDate *)date forURL:(NSURL *)fileURL
{
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    TMDiskCacheError(error);

    if (success)
        [_dates setObject:date forKey:[self keyForEncodedFileURL:fileURL]];

    return success;
}

- (BOOL)saveStoreDates
{
    NSError *error = nil;
    BOOL written = [NSKeyedArchiver archiveRootObject:_storeDates toFile:[_storeDatesURL path]];
    TMDiskCacheError(error);

    return written;
}

- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key
{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]])
        return NO;

    if (_willRemoveObjectBlock)
        _willRemoveObjectBlock(self, key, nil, fileURL);

    NSError *error = nil;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
    TMDiskCacheError(error);

    if (!removed)
        return NO;

    NSNumber *byteSize = [_sizes objectForKey:key];
    if (byteSize)
        self.byteCount = _byteCount - [byteSize unsignedIntegerValue]; // atomic

    [_sizes removeObjectForKey:key];
    [_dates removeObjectForKey:key];
    [_storeDates removeObjectForKey:key];

    [self saveStoreDates];

    if (_didRemoveObjectBlock)
        _didRemoveObjectBlock(self, key, nil, fileURL);

    return YES;
}

- (void)trimDiskToSize:(NSUInteger)trimByteCount
{
    if (_byteCount <= trimByteCount)
        return;

    NSArray *keysSortedBySize = [_sizes keysSortedByValueUsingSelector:@selector(compare:)];

    for (NSString *key in [keysSortedBySize reverseObjectEnumerator]) { // largest objects first
        [self removeFileAndExecuteBlocksForKey:key];

        if (_byteCount <= trimByteCount)
            break;
    }
}

- (void)trimDiskToSizeByDate:(NSUInteger)trimByteCount
{
    if (_byteCount <= trimByteCount)
        return;

    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];

    for (NSString *key in keysSortedByDate) { // oldest objects first
        [self removeFileAndExecuteBlocksForKey:key];

        if (_byteCount <= trimByteCount)
            break;
    }
}

- (void)trimDiskToDate:(NSDate *)trimDate
{
    NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    
    for (NSString *key in keysSortedByDate) { // oldest files first
        NSDate *accessDate = [_dates objectForKey:key];
        if (!accessDate)
            continue;
        
        if ([accessDate compare:trimDate] == NSOrderedAscending) { // older than trim date
            [self removeFileAndExecuteBlocksForKey:key];
        } else {
            break;
        }
    }
}

- (void)trimToAgeLimitRecursively
{
    if (_ageLimit == 0.0)
        return;
    
    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-_ageLimit];
    [self trimDiskToDate:date];
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_ageLimit * NSEC_PER_SEC));
    dispatch_after(time, _queue, ^(void) {
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf trimToAgeLimitRecursively];
    });
}

#pragma mark - Public Asynchronous Methods -

- (void)objectForKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];

    if (!key || !block)
        return;

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        id <NSCoding> object = nil;

        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            object = [NSKeyedUnarchiver unarchiveObjectWithFile:[fileURL path]];
            [strongSelf setFileModificationDate:now forURL:fileURL];
        }

        block(strongSelf, key, object, fileURL);
    });
}

- (void)fileURLForKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];

    if (!key || !block)
        return;

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];

        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
        } else {
            fileURL = nil;
        }

        block(strongSelf, key, nil, fileURL);
    });
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    NSDate *now = [[NSDate alloc] init];

    if (!key || !object)
        return;

    TMCacheStartBackgroundTask();

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];

        if (strongSelf->_willAddObjectBlock)
            strongSelf->_willAddObjectBlock(strongSelf, key, object, fileURL);

        NSError *error = nil;
        BOOL written = [NSKeyedArchiver archiveRootObject:object toFile:[fileURL path]];
        TMDiskCacheError(error);

        if (written) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
            [strongSelf->_storeDates setObject:[[NSDate alloc] init] forKey:key];
            [strongSelf saveStoreDates];

            error = nil;
            NSDictionary *values = [fileURL resourceValuesForKeys:@[ NSURLTotalFileAllocatedSizeKey ] error:&error];
            TMDiskCacheError(error);

            NSNumber *diskFileSize = [values objectForKey:NSURLTotalFileAllocatedSizeKey];
            if (diskFileSize) {
                [strongSelf->_sizes setObject:diskFileSize forKey:key];
                strongSelf.byteCount = strongSelf->_byteCount + [diskFileSize unsignedIntegerValue]; // atomic
            }
            
            if (strongSelf->_byteLimit > 0 && strongSelf->_byteCount > strongSelf->_byteLimit)
                [strongSelf trimToSizeByDate:strongSelf->_byteLimit block:nil];
        } else {
            fileURL = nil;
        }

        if (strongSelf->_didAddObjectBlock)
            strongSelf->_didAddObjectBlock(strongSelf, key, object, written ? fileURL : nil);

        if (block)
            block(strongSelf, key, object, fileURL);

        TMCacheEndBackgroundTask();
    });
}

- (void)removeObjectForKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    if (!key)
        return;

    TMCacheStartBackgroundTask();

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
        [strongSelf removeFileAndExecuteBlocksForKey:key];

        if (block)
            block(strongSelf, key, nil, fileURL);

        TMCacheEndBackgroundTask();
    });
}

- (void)removeObjectForKey:(NSString *)key olderThan:(NSDate *)date block:(TMDiskCacheObjectBlock)block
{
    if (!key)
        return;

    NSDate *storeDate = [_storeDates objectForKey:key];

    if ([storeDate compare:date] == NSOrderedAscending) {
        [self removeObjectForKey:key block:block];
    } else {
        NSURL *fileURL = [self encodedFileURLForKey:key];
        block(self, key, nil, fileURL);
    }
}

- (void)trimToSize:(NSUInteger)trimByteCount block:(TMDiskCacheBlock)block
{
    if (trimByteCount == 0) {
        [self removeAllObjects:block];
        return;
    }

    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        [strongSelf trimDiskToSize:trimByteCount];

        if (block)
            block(strongSelf);
        
        TMCacheEndBackgroundTask();
    });
}

- (void)trimToDate:(NSDate *)trimDate block:(TMDiskCacheBlock)block
{
    if (!trimDate)
        return;

    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects:block];
        return;
    }
    
    TMCacheStartBackgroundTask();

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        [strongSelf trimDiskToDate:trimDate];

        if (block)
            block(strongSelf);
        
        TMCacheEndBackgroundTask();
    });
}

- (void)trimToSizeByDate:(NSUInteger)trimByteCount block:(TMDiskCacheBlock)block
{
    if (trimByteCount == 0) {
        [self removeAllObjects:block];
        return;
    }

    TMCacheStartBackgroundTask();

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        [strongSelf trimDiskToSizeByDate:trimByteCount];

        if (block)
            block(strongSelf);

        TMCacheEndBackgroundTask();
    });
}

- (void)removeAllObjects:(TMDiskCacheBlock)block
{
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        if (strongSelf->_willRemoveAllObjectsBlock)
            strongSelf->_willRemoveAllObjectsBlock(strongSelf);

        if ([[NSFileManager defaultManager] fileExistsAtPath:[strongSelf->_cacheURL path]]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtURL:strongSelf->_cacheURL error:&error];
            TMDiskCacheError(error);
        }

        [strongSelf createCacheDirectory];

        [strongSelf->_dates removeAllObjects];
        [strongSelf->_storeDates removeAllObjects];
        [strongSelf->_sizes removeAllObjects];
        strongSelf.byteCount = 0; // atomic

        if (strongSelf->_didRemoveAllObjectsBlock)
            strongSelf->_didRemoveAllObjectsBlock(strongSelf);

        if (block)
            block(strongSelf);
        
        TMCacheEndBackgroundTask();
    });
}

- (void)enumerateObjectsWithBlock:(TMDiskCacheObjectBlock)block completionBlock:(TMDiskCacheBlock)completionBlock
{
    if (!block)
        return;

    TMCacheStartBackgroundTask();

    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            TMCacheEndBackgroundTask();
            return;
        }

        NSArray *keysSortedByDate = [strongSelf->_dates keysSortedByValueUsingSelector:@selector(compare:)];

        for (NSString *key in keysSortedByDate) {
            NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
            block(strongSelf, key, nil, fileURL);
        }

        if (completionBlock)
            completionBlock(strongSelf);

        TMCacheEndBackgroundTask();
    });
}

#pragma mark - Public Synchronous Methods -

- (id <NSCoding>)objectForKey:(NSString *)key
{
    if (!key)
        return nil;

    __block id <NSCoding> objectForKey = nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self objectForKey:key block:^(TMDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        objectForKey = object;
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif

    return objectForKey;
}

- (NSURL *)fileURLForKey:(NSString *)key
{
    if (!key)
        return nil;

    __block NSURL *fileURLForKey = nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self fileURLForKey:key block:^(TMDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        fileURLForKey = fileURL;
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif

    return fileURLForKey;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    if (!object || !key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self setObject:object forKey:key block:^(TMDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self removeObjectForKey:key block:^(TMDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)removeObjectForKey:(NSString *)key olderThan:(NSDate *)date
{
    if (!key)
        return;
    
    NSDate *storeDate = [_storeDates objectForKey:key];
    
    if ([storeDate compare:date] == NSOrderedAscending) {
        [self removeObjectForKey:key];
    }
}

- (void)trimToSize:(NSUInteger)byteCount
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self trimToSize:byteCount block:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)trimToDate:(NSDate *)date
{
    if (!date)
        return;

    if ([date isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self trimToDate:date block:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)trimToSizeByDate:(NSUInteger)byteCount
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self trimToSizeByDate:byteCount block:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)removeAllObjects
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self removeAllObjects:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (void)enumerateObjectsWithBlock:(TMDiskCacheObjectBlock)block
{
    if (!block)
        return;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [self enumerateObjectsWithBlock:block completionBlock:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(semaphore);
    #endif
}

- (NSDate *)storeDateForKey:(NSString *)key
{
    return [_storeDates objectForKey:key];
}

#pragma mark - Public Thread Safe Accessors -

- (TMDiskCacheObjectBlock)willAddObjectBlock
{
    __block TMDiskCacheObjectBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _willAddObjectBlock;
    });

    return block;
}

- (void)setWillAddObjectBlock:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_willAddObjectBlock = [block copy];
    });
}

- (TMDiskCacheObjectBlock)willRemoveObjectBlock
{
    __block TMDiskCacheObjectBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _willRemoveObjectBlock;
    });

    return block;
}

- (void)setWillRemoveObjectBlock:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_willRemoveObjectBlock = [block copy];
    });
}

- (TMDiskCacheBlock)willRemoveAllObjectsBlock
{
    __block TMDiskCacheBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _willRemoveAllObjectsBlock;
    });

    return block;
}

- (void)setWillRemoveAllObjectsBlock:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_willRemoveAllObjectsBlock = [block copy];
    });
}

- (TMDiskCacheObjectBlock)didAddObjectBlock
{
    __block TMDiskCacheObjectBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _didAddObjectBlock;
    });

    return block;
}

- (void)setDidAddObjectBlock:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_didAddObjectBlock = [block copy];
    });
}

- (TMDiskCacheObjectBlock)didRemoveObjectBlock
{
    __block TMDiskCacheObjectBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _didRemoveObjectBlock;
    });

    return block;
}

- (void)setDidRemoveObjectBlock:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_didRemoveObjectBlock = [block copy];
    });
}

- (TMDiskCacheBlock)didRemoveAllObjectsBlock
{
    __block TMDiskCacheBlock block = nil;

    dispatch_sync(_queue, ^{
        block = _didRemoveAllObjectsBlock;
    });

    return block;
}

- (void)setDidRemoveAllObjectsBlock:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf->_didRemoveAllObjectsBlock = [block copy];
    });
}

- (NSUInteger)byteLimit
{
    __block NSUInteger byteLimit = 0;
    
    dispatch_sync(_queue, ^{
        byteLimit = _byteLimit;
    });
    
    return byteLimit;
}

- (void)setByteLimit:(NSUInteger)byteLimit
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_byteLimit = byteLimit;

        if (byteLimit > 0)
            [strongSelf trimDiskToSizeByDate:byteLimit];
    });
}

- (NSTimeInterval)ageLimit
{
    __block NSTimeInterval ageLimit = 0.0;
    
    dispatch_sync(_queue, ^{
        ageLimit = _ageLimit;
    });
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_barrier_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_ageLimit = ageLimit;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}

@end
