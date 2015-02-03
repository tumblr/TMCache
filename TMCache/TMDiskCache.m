#import "TMDiskCache.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

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

@interface TMDiskCache ()
@property (assign) NSUInteger byteCount;
@property (strong, nonatomic) NSURL *cacheURL;
@property (assign, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) NSMutableDictionary *dates;
@property (strong, nonatomic) NSMutableDictionary *sizes;
#if OS_OBJECT_USE_OBJC
@property (strong, nonatomic) dispatch_queue_t asyncQueue;
#else
@property (assign, nonatomic) dispatch_queue_t asyncQueue;
#endif
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

- (void)dealloc
{
#if !OS_OBJECT_USE_OBJC
    dispatch_release(_asyncQueue);
    _asyncQueue = nil;
#endif
}

- (instancetype)initWithName:(NSString *)name
{
    return [self initWithName:name rootPath:[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0]];
}

- (instancetype)initWithName:(NSString *)name rootPath:(NSString *)rootPath
{
    if (!name)
        return nil;

    if (self = [super init]) {
        _name = [name copy];
        _queue = [TMDiskCache sharedQueue];
        _asyncQueue = dispatch_queue_create([[NSString stringWithFormat:@"%@ Asynchronous Queue", TMDiskCachePrefix] UTF8String], DISPATCH_QUEUE_CONCURRENT);

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
        _sizes = [[NSMutableDictionary alloc] init];

        NSString *pathComponent = [[NSString alloc] initWithFormat:@"%@.%@", TMDiskCachePrefix, _name];
        _cacheURL = [NSURL fileURLWithPathComponents:@[ rootPath, pathComponent ]];

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

#pragma mark - Private Trash Methods -

+ (dispatch_queue_t)sharedTrashQueue
{
    static dispatch_queue_t trashQueue;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.trash", TMDiskCachePrefix];
        trashQueue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(trashQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    });
    
    return trashQueue;
}

+ (NSURL *)sharedTrashURL
{
    static NSURL *sharedTrashURL;
    static dispatch_once_t predicate;
    
    dispatch_once(&predicate, ^{
        sharedTrashURL = [[[NSURL alloc] initFileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:TMDiskCachePrefix isDirectory:YES];
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:[sharedTrashURL path]]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtURL:sharedTrashURL
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&error];
            TMDiskCacheError(error);
        }
    });
    
    return sharedTrashURL;
}

+(BOOL)moveItemAtURLToTrash:(NSURL *)itemURL
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:[itemURL path]])
        return NO;

    NSError *error = nil;
    NSString *uniqueString = [[NSProcessInfo processInfo] globallyUniqueString];
    NSURL *uniqueTrashURL = [[TMDiskCache sharedTrashURL] URLByAppendingPathComponent:uniqueString];
    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:itemURL toURL:uniqueTrashURL error:&error];
    TMDiskCacheError(error);
    return moved;
}

+ (void)emptyTrash
{
    TMCacheStartBackgroundTask();
    
    dispatch_async([self sharedTrashQueue], ^{        
        NSError *error = nil;
        NSArray *trashedItems = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self sharedTrashURL]
                                                              includingPropertiesForKeys:nil
                                                                                 options:0
                                                                                   error:&error];
        TMDiskCacheError(error);

        for (NSURL *trashedItemURL in trashedItems) {
            NSError *error = nil;
            [[NSFileManager defaultManager] removeItemAtURL:trashedItemURL error:&error];
            TMDiskCacheError(error);
        }
            
        TMCacheEndBackgroundTask();
    });
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

    for (NSURL *fileURL in files) {
        NSString *key = [self keyForEncodedFileURL:fileURL];

        error = nil;
        NSDictionary *dictionary = [fileURL resourceValuesForKeys:keys error:&error];
        TMDiskCacheError(error);

        NSDate *date = [dictionary objectForKey:NSURLContentModificationDateKey];
        if (date && key)
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
    if (!date || !fileURL) {
        return NO;
    }
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date }
                                                    ofItemAtPath:[fileURL path]
                                                           error:&error];
    TMDiskCacheError(error);

    if (success) {
        NSString *key = [self keyForEncodedFileURL:fileURL];
        if (key) {
            [_dates setObject:date forKey:key];
        }
    }

    return success;
}

- (BOOL)removeFileAndExecuteBlocksForKey:(NSString *)key
{
    NSURL *fileURL = [self encodedFileURLForKey:key];
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]])
        return NO;

    if (_willRemoveObjectBlock)
        _willRemoveObjectBlock(self, key, nil, fileURL);

    BOOL trashed = [TMDiskCache moveItemAtURLToTrash:fileURL];
    if (!trashed)
        return NO;
    
    [TMDiskCache emptyTrash];

    NSNumber *byteSize = [_sizes objectForKey:key];
    if (byteSize)
        self.byteCount = _byteCount - [byteSize unsignedIntegerValue]; // atomic

    [_sizes removeObjectForKey:key];
    [_dates removeObjectForKey:key];

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
    __weak TMDiskCache *weakSelf = self;

    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = nil;
        id <NSCoding> object = [strongSelf objectForKey:key fileURL:&fileURL];

        if (block)
            block(strongSelf, key, object, fileURL);
    });
}

- (void)fileURLForKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = [strongSelf fileURLForKey:key];
        
        if (block)
            block(strongSelf, key, nil, fileURL);
    });
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = nil;
        [strongSelf setObject:object forKey:key fileURL:&fileURL];
        
        if (block)
            block(strongSelf, key, object, fileURL);
    });
}

- (void)removeObjectForKey:(NSString *)key block:(TMDiskCacheObjectBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        NSURL *fileURL = nil;
        [strongSelf removeObjectForKey:key fileURL:&fileURL];
        
        if (block)
            block(strongSelf, key, nil, fileURL);
    });
}

- (void)trimToSize:(NSUInteger)trimByteCount block:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf trimToSize:trimByteCount];
        
        if (block)
            block(strongSelf);
    });
}

- (void)trimToDate:(NSDate *)trimDate block:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf trimToDate:trimDate];
        
        if (block)
            block(strongSelf);
    });
}

- (void)trimToSizeByDate:(NSUInteger)trimByteCount block:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf trimToSizeByDate:trimByteCount];
        
        if (block)
            block(strongSelf);
    });
}

- (void)removeAllObjects:(TMDiskCacheBlock)block
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf removeAllObjects];
        
        if (block)
            block(strongSelf);
    });
}

- (void)enumerateObjectsWithBlock:(TMDiskCacheObjectBlock)block completionBlock:(TMDiskCacheBlock)completionBlock
{
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_async(_asyncQueue, ^{
        TMDiskCache *strongSelf = weakSelf;
        [strongSelf enumerateObjectsWithBlock:block];
        
        if (completionBlock)
            completionBlock(strongSelf);
    });
}

#pragma mark - Public Synchronous Methods -

- (id <NSCoding>)objectForKey:(NSString *)key
{
    return [self objectForKey:key fileURL:nil];
}

- (id <NSCoding>)objectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key)
        return nil;
    
    __weak TMDiskCache *weakSelf = self;
    __block id <NSCoding> object = nil;
    __block NSURL *fileURL = nil;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        fileURL = [strongSelf encodedFileURLForKey:key];
        object = nil;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
			@try {
	            object = [NSKeyedUnarchiver unarchiveObjectWithFile:[fileURL path]];
			}
			@catch (NSException *exception) {
				NSError *error = nil;
				[[NSFileManager defaultManager] removeItemAtPath:[fileURL path] error:&error];
				TMDiskCacheError(error);
			}
			
            [strongSelf setFileModificationDate:now forURL:fileURL];
        }
    });
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    
    return object;
}

- (NSURL *)fileURLForKey:(NSString *)key
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key)
        return nil;
    
    __weak TMDiskCache *weakSelf = self;
    __block NSURL *fileURL = nil;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        fileURL = [strongSelf encodedFileURLForKey:key];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
        } else {
            fileURL = nil;
        }
    });
    return fileURL;
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key
{
    [self setObject:object forKey:key fileURL:nil];
}

- (void)setObject:(id <NSCoding>)object forKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key || !object)
        return;
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    __block NSURL *fileURL = nil;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        fileURL = [strongSelf encodedFileURLForKey:key];
        
        if (strongSelf->_willAddObjectBlock)
            strongSelf->_willAddObjectBlock(strongSelf, key, object, fileURL);
        
        BOOL written = [NSKeyedArchiver archiveRootObject:object toFile:[fileURL path]];
        
        if (written) {
            [strongSelf setFileModificationDate:now forURL:fileURL];
            
            NSError *error = nil;
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
    });
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
    
    TMCacheEndBackgroundTask();
}

- (void)removeObjectForKey:(NSString *)key
{
    [self removeObjectForKey:key fileURL:nil];
}

- (void)removeObjectForKey:(NSString *)key fileURL:(NSURL **)outFileURL
{
    if (!key)
        return;
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    __block NSURL *fileURL = nil;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        fileURL = [strongSelf encodedFileURLForKey:key];
        [strongSelf removeFileAndExecuteBlocksForKey:key];
    });
    
    TMCacheEndBackgroundTask();
    
    if (outFileURL) {
        *outFileURL = fileURL;
    }
}

- (void)trimToSize:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        [strongSelf trimDiskToSize:trimByteCount];
    });
    
    TMCacheEndBackgroundTask();
}

- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        [strongSelf trimDiskToDate:trimDate];
    });
    
    TMCacheEndBackgroundTask();
}

- (void)trimToSizeByDate:(NSUInteger)trimByteCount
{
    if (trimByteCount == 0) {
        [self removeAllObjects];
        return;
    }
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        [strongSelf trimDiskToSizeByDate:trimByteCount];
    });
    
    TMCacheEndBackgroundTask();
}

- (void)removeAllObjects
{
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        if (strongSelf->_willRemoveAllObjectsBlock)
            strongSelf->_willRemoveAllObjectsBlock(strongSelf);
        
        [TMDiskCache moveItemAtURLToTrash:strongSelf->_cacheURL];
        [TMDiskCache emptyTrash];
        
        [strongSelf createCacheDirectory];
        
        [strongSelf->_dates removeAllObjects];
        [strongSelf->_sizes removeAllObjects];
        strongSelf.byteCount = 0; // atomic
        
        if (strongSelf->_didRemoveAllObjectsBlock)
            strongSelf->_didRemoveAllObjectsBlock(strongSelf);
    });
    
    TMCacheEndBackgroundTask();
}

- (void)enumerateObjectsWithBlock:(TMDiskCacheObjectBlock)block
{
    if (!block)
        return;
    
    TMCacheStartBackgroundTask();
    
    __weak TMDiskCache *weakSelf = self;
    
    dispatch_sync(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        
        NSArray *keysSortedByDate = [strongSelf->_dates keysSortedByValueUsingSelector:@selector(compare:)];
        
        for (NSString *key in keysSortedByDate) {
            NSURL *fileURL = [strongSelf encodedFileURLForKey:key];
            block(strongSelf, key, nil, fileURL);
        }
    });
    
    TMCacheEndBackgroundTask();
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
    
    dispatch_async(_queue, ^{
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
    
    dispatch_async(_queue, ^{
        TMDiskCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        strongSelf->_ageLimit = ageLimit;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}

@end
