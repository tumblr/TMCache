#import "TMCacheTests.h"
#import "TMCache.h"

NSString * const TMCacheTestName = @"TMCacheTest";
NSTimeInterval TMCacheTestBlockTimeout = 5.0;

@interface TMCacheTests ()
@property (strong, nonatomic) TMCache *cache;
@end

@implementation TMCacheTests

#pragma mark - SenTestCase -

- (void)setUp
{
    [super setUp];
    
    self.cache = [[TMCache alloc] initWithName:TMCacheTestName];
    
    STAssertNotNil(self.cache, @"test cache does not exist");
}

- (void)tearDown
{
    [self.cache removeAllObjects];

    self.cache = nil;

    STAssertNil(self.cache, @"test cache did not deallocate");
    
    [super tearDown];
}

#pragma mark - Private Methods

- (UIImage *)image
{
    static UIImage *image = nil;
    
    if (!image) {
        NSError *error = nil;
        NSURL *imageURL = [[NSBundle mainBundle] URLForResource:@"Default-568h@2x" withExtension:@"png"];
        NSData *imageData = [[NSData alloc] initWithContentsOfURL:imageURL
                                                          options:NSDataReadingUncached
                                                            error:&error];
        image = [[UIImage alloc] initWithData:imageData scale:2.f];
    }

    NSAssert(image, @"test image does not exist");

    return image;
}

- (dispatch_time_t)timeout
{
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TMCacheTestBlockTimeout * NSEC_PER_SEC));
}

#pragma mark - Tests -

- (void)testCoreProperties
{
    STAssertTrue([self.cache.name isEqualToString:TMCacheTestName], @"wrong name");
    STAssertNotNil(self.cache.memoryCache, @"memory cache does not exist");
    STAssertNotNil(self.cache.diskCache, @"disk cache doe not exist");
}

- (void)testDiskCacheURL
{
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[self.cache.diskCache.cacheURL path] isDirectory:&isDir];

    STAssertTrue(exists, @"disk cache directory does not exist");
    STAssertTrue(isDir, @"disk cache url is not a directory");
}

- (void)testObjectSet
{
    NSString *key = @"key";
    __block UIImage *image = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self.cache setObject:[self image] forKey:key block:^(TMCache *cache, NSString *key, id object) {
        image = (UIImage *)object;
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, [self timeout]);
    
    STAssertNotNil(image, @"object was not set");
}

- (void)testObjectGet
{
    NSString *key = @"key";
    __block UIImage *image = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self.cache setObject:[self image] forKey:key];
    
    [self.cache objectForKey:key block:^(TMCache *cache, NSString *key, id object) {
        image = (UIImage *)object;
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, [self timeout]);
    
    STAssertNotNil(image, @"object was not got");
}

- (void)testObjectRemove
{
    NSString *key = @"key";
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    [self.cache setObject:[self image] forKey:key];
    
    [self.cache removeObjectForKey:key block:^(TMCache *cache, NSString *key, id object) {
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, [self timeout]);
    
    id object = [self.cache objectForKey:key];
    
    STAssertNil(object, @"object was not removed");
}

- (void)testObjectExpiryTime
{
    NSString *key1 = @"key1";
    NSString *key2 = @"key2";
    
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    //Timer has a loop of 1.1 seconds, just to give some time to clear objects from cache
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC), 0);
    //dispatch_source_set_event_handler is called very first time which will update timerFiredCount to 0
    __block int timerFiredCount = -1;
    
    dispatch_source_set_event_handler(timer, ^{
        
        timerFiredCount++;
        
//        For debugging purpose
//        NSString *object1 = [self.cache.memoryCache objectForKey:key1];
//        NSString *object2 = [self.cache.memoryCache objectForKey:key2];
//        NSString* log = [NSString stringWithFormat:@"\n\n  [%d]  %f object 1 : %@, object 2 : %@  [%lu]\n\n", timerFiredCount, [[NSDate date] timeIntervalSinceReferenceDate], object1, object2, (unsigned long)self.cache.memoryCache.totalCost];
//        CFShow((__bridge CFTypeRef)(log)); // NSLog output is not clean
        
        switch (timerFiredCount) {
            case 0:
                STAssertTrue(self.cache.memoryCache.totalCost == 3, @"cache had an unexpected total cost before any object expired");
                break;
            case 1:
                STAssertTrue(self.cache.memoryCache.totalCost == 2, @"cache had an unexpected total cost after first object expired");
                break;
            case 2:
                break;
            case 3:
                STAssertTrue(self.cache.memoryCache.totalCost == 0, @"cache had an unexpected total cost after all objects expired");
                dispatch_semaphore_signal(semaphore);
                break;
            default:
                break;
        }
        
    });
    
    [self.cache.memoryCache setObject:key1 forKey:key1 withCost:1 andLife:1];
    [self.cache.memoryCache setObject:key2 forKey:key2 withCost:2 andLife:2];
    
    if(timer != nil) {
        dispatch_resume(timer);
    }

    dispatch_semaphore_wait(semaphore, [self timeout]);
    
    if(timer) {
        dispatch_source_cancel(timer);
    }
}

- (void)testMemoryCost
{
    NSString *key1 = @"key1";
    NSString *key2 = @"key2";

    [self.cache.memoryCache setObject:key1 forKey:key1 withCost:1];
    [self.cache.memoryCache setObject:key2 forKey:key2 withCost:2];
    
    STAssertTrue(self.cache.memoryCache.totalCost == 3, @"memory cache total cost was incorrect");

    [self.cache.memoryCache trimToCost:1];

    id object1 = [self.cache.memoryCache objectForKey:key1];
    id object2 = [self.cache.memoryCache objectForKey:key2];

    STAssertNotNil(object1, @"object did not survive memory cache trim to cost");
    STAssertNil(object2, @"object was not trimmed despite exceeding cost");
    STAssertTrue(self.cache.memoryCache.totalCost == 1, @"cache had an unexpected total cost");
}

- (void)testMemoryCostByDate
{
    NSString *key1 = @"key1";
    NSString *key2 = @"key2";

    [self.cache.memoryCache setObject:key1 forKey:key1 withCost:1];
    [self.cache.memoryCache setObject:key2 forKey:key2 withCost:2];

    [self.cache.memoryCache trimToCostByDate:1];

    id object1 = [self.cache.memoryCache objectForKey:key1];
    id object2 = [self.cache.memoryCache objectForKey:key2];

    STAssertNil(object1, @"object was not trimmed despite exceeding cost");
    STAssertNil(object2, @"object was not trimmed despite exceeding cost");
    STAssertTrue(self.cache.memoryCache.totalCost == 0, @"cache had an unexpected total cost");
}

- (void)testDiskByteCount
{
    [self.cache setObject:[self image] forKey:@"image"];
    
    STAssertTrue(self.cache.diskByteCount > 0, @"disk cache byte count was not greater than zero");
}

- (void)testOneThousandAndOneWrites
{
    NSUInteger max = 1001;
    __block NSInteger count = max;

    dispatch_queue_t queue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    dispatch_group_t group = dispatch_group_create();
    
    for (NSUInteger i = 0; i < max; i++) {
        NSString *key = [[NSString alloc] initWithFormat:@"key %ld", i];
        NSString *obj = [[NSString alloc] initWithFormat:@"obj %ld", i];
        
        [self.cache setObject:obj forKey:key block:nil];

        dispatch_group_enter(group);
    }
    
    for (NSUInteger i = 0; i < max; i++) {
        NSString *key = [[NSString alloc] initWithFormat:@"key %ld", i];
        
        [self.cache objectForKey:key block:^(TMCache *cache, NSString *key, id object) {
            dispatch_async(queue, ^{
                count -= 1;
                dispatch_group_leave(group);
            });
        }];
    }
    
    dispatch_group_wait(group, [self timeout]);

    STAssertTrue(count == 0, @"one or more object blocks failed to execute, possible queue deadlock");
}

- (void)testMemoryWarningBlock
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block BOOL blockDidExecute = NO;

    self.cache.memoryCache.didReceiveMemoryWarningBlock = ^(TMMemoryCache *cache) {
        blockDidExecute = YES;
        dispatch_semaphore_signal(semaphore);
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:[UIApplication sharedApplication]];

    dispatch_semaphore_wait(semaphore, [self timeout]);

    STAssertTrue(blockDidExecute, @"memory warning block did not execute");
}

- (void)testBackgroundBlock
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block BOOL blockDidExecute = NO;

    self.cache.memoryCache.didEnterBackgroundBlock = ^(TMMemoryCache *cache) {
        blockDidExecute = YES;
        dispatch_semaphore_signal(semaphore);
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidEnterBackgroundNotification
                                                        object:[UIApplication sharedApplication]];

    dispatch_semaphore_wait(semaphore, [self timeout]);

    STAssertTrue(blockDidExecute, @"app background block did not execute");
}

- (void)testMemoryWarningProperty
{
    [self.cache.memoryCache setObject:@"object" forKey:@"object" block:nil];

    self.cache.memoryCache.removeAllObjectsOnMemoryWarning = NO;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block id object = nil;
    
    self.cache.memoryCache.didReceiveMemoryWarningBlock = ^(TMMemoryCache *cache) {
        object = [cache objectForKey:@"object"];
        dispatch_semaphore_signal(semaphore);
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:[UIApplication sharedApplication]];

    dispatch_semaphore_wait(semaphore, [self timeout]);

    STAssertNotNil(object, @"object was removed from the cache");
}

- (void)testMemoryCacheEnumerationWithWarning
{
    NSUInteger objectCount = 3;

    dispatch_apply(objectCount, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
        NSString *key = [[NSString alloc] initWithFormat:@"key %zd", index];
        NSString *obj = [[NSString alloc] initWithFormat:@"obj %zd", index];
        [self.cache.memoryCache setObject:obj forKey:key block:nil];
    });

    self.cache.memoryCache.removeAllObjectsOnMemoryWarning = NO;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block NSUInteger enumCount = 0;

    self.cache.memoryCache.didReceiveMemoryWarningBlock = ^(TMMemoryCache *cache) {
        [cache enumerateObjectsWithBlock:^(TMMemoryCache *cache, NSString *key, id object) {
            enumCount++;
        } completionBlock:^(TMMemoryCache *cache) {
            dispatch_semaphore_signal(semaphore);
        }];
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:[UIApplication sharedApplication]];

    dispatch_semaphore_wait(semaphore, [self timeout]);

    STAssertTrue(objectCount == enumCount, @"some objects were not enumerated");
}

- (void)testDiskCacheEnumeration
{
    NSUInteger objectCount = 3;

    dispatch_apply(objectCount, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
        NSString *key = [[NSString alloc] initWithFormat:@"key %zd", index];
        NSString *obj = [[NSString alloc] initWithFormat:@"obj %zd", index];
        [self.cache.diskCache setObject:obj forKey:key block:nil];
    });

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block NSUInteger enumCount = 0;

    [self.cache.diskCache enumerateObjectsWithBlock:^(TMDiskCache *cache, NSString *key, id <NSCoding> object, NSURL *fileURL) {
        enumCount++;
    } completionBlock:^(TMDiskCache *cache) {
        dispatch_semaphore_signal(semaphore);
    }];

    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationDidReceiveMemoryWarningNotification
                                                        object:[UIApplication sharedApplication]];

    dispatch_semaphore_wait(semaphore, [self timeout]);

    STAssertTrue(objectCount == enumCount, @"some objects were not enumerated");
}

@end
