#import "TMMemoryCache.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
#import <UIKit/UIKit.h>
#endif

NSString * const TMMemoryCachePrefix = @"com.tumblr.TMMemoryCache";

@interface TMMemoryCache ()
#if OS_OBJECT_USE_OBJC
@property (strong, nonatomic) dispatch_queue_t queue;
@property (strong, nonatomic) dispatch_semaphore_t lock;
#else
@property (assign, nonatomic) dispatch_queue_t queue;
@property (assign, nonatomic) dispatch_semaphore_t lock;
#endif
@property (strong, nonatomic) NSMutableDictionary *dictionary;
@property (strong, nonatomic) NSMutableDictionary *dates;
@property (strong, nonatomic) NSMutableDictionary *costs;
@end

@implementation TMMemoryCache

@synthesize ageLimit = _ageLimit;
@synthesize costLimit = _costLimit;
@synthesize totalCost = _totalCost;
@synthesize willAddObjectBlock = _willAddObjectBlock;
@synthesize willRemoveObjectBlock = _willRemoveObjectBlock;
@synthesize willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
@synthesize didAddObjectBlock = _didAddObjectBlock;
@synthesize didRemoveObjectBlock = _didRemoveObjectBlock;
@synthesize didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
@synthesize didReceiveMemoryWarningBlock = _didReceiveMemoryWarningBlock;
@synthesize didEnterBackgroundBlock = _didEnterBackgroundBlock;

#pragma mark - Initialization -

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    #if !OS_OBJECT_USE_OBJC
    dispatch_release(_queue);
    dispatch_release(_lock);
    _queue = nil;
    #endif
}

- (id)init
{
    if (self = [super init]) {
        _lock = dispatch_semaphore_create(1);
        NSString *queueName = [[NSString alloc] initWithFormat:@"%@.%p", TMMemoryCachePrefix, self];
        _queue = dispatch_queue_create([queueName UTF8String], DISPATCH_QUEUE_CONCURRENT);

        _dictionary = [[NSMutableDictionary alloc] init];
        _dates = [[NSMutableDictionary alloc] init];
        _costs = [[NSMutableDictionary alloc] init];

        _willAddObjectBlock = nil;
        _willRemoveObjectBlock = nil;
        _willRemoveAllObjectsBlock = nil;

        _didAddObjectBlock = nil;
        _didRemoveObjectBlock = nil;
        _didRemoveAllObjectsBlock = nil;

        _didReceiveMemoryWarningBlock = nil;
        _didEnterBackgroundBlock = nil;

        _ageLimit = 0.0;
        _costLimit = 0;
        _totalCost = 0;

        _removeAllObjectsOnMemoryWarning = YES;
        _removeAllObjectsOnEnteringBackground = YES;

        #if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
        for (NSString *name in @[UIApplicationDidReceiveMemoryWarningNotification, UIApplicationDidEnterBackgroundNotification]) {
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(didObserveApocalypticNotification:)
                                                         name:name
                                                       object:[UIApplication sharedApplication]];
        }
        #endif
    }
    return self;
}

+ (instancetype)sharedCache
{
    static id cache;
    static dispatch_once_t predicate;

    dispatch_once(&predicate, ^{
        cache = [[self alloc] init];
    });

    return cache;
}

#pragma mark - Private Methods -

- (void)didObserveApocalypticNotification:(NSNotification *)notification
{
    #if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0

    if ([[notification name] isEqualToString:UIApplicationDidReceiveMemoryWarningNotification]) {
        if (self.removeAllObjectsOnMemoryWarning)
            [self removeAllObjects:nil];

        __weak TMMemoryCache *weakSelf = self;

        dispatch_async(_queue, ^{
            TMMemoryCache *strongSelf = weakSelf;
            if (!strongSelf)
                return;
            
            [self lockForReading];
                TMMemoryCacheBlock didReceiveMemoryWarningBlock = strongSelf->_didReceiveMemoryWarningBlock;
            [self unlockForReading];
            
            if (didReceiveMemoryWarningBlock)
                didReceiveMemoryWarningBlock(strongSelf);
        });
    } else if ([[notification name] isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        if (self.removeAllObjectsOnEnteringBackground)
            [self removeAllObjects:nil];

        __weak TMMemoryCache *weakSelf = self;

        dispatch_async(_queue, ^{
            TMMemoryCache *strongSelf = weakSelf;
            if (!strongSelf)
                return;

            [self lockForReading];
                TMMemoryCacheBlock didEnterBackgroundBlock = strongSelf->_didEnterBackgroundBlock;
            [self unlockForReading];
            
            if (didEnterBackgroundBlock)
                didEnterBackgroundBlock(strongSelf);
        });
    }
    
    #endif
}

- (void)removeObjectAndExecuteBlocksForKey:(NSString *)key
{
    [self lockForReading];
        id object = [_dictionary objectForKey:key];
        NSNumber *cost = [_costs objectForKey:key];
        TMMemoryCacheObjectBlock willRemoveObjectBlock = _willRemoveObjectBlock;
        TMMemoryCacheObjectBlock didRemoveObjectBlock = _didRemoveObjectBlock;
    [self unlockForReading];

    if (willRemoveObjectBlock)
        willRemoveObjectBlock(self, key, object);

    [self lockForWriting];
        if (cost)
            _totalCost -= [cost unsignedIntegerValue];

        [_dictionary removeObjectForKey:key];
        [_dates removeObjectForKey:key];
        [_costs removeObjectForKey:key];
    [self unlockForWriting];
    
    if (didRemoveObjectBlock)
        didRemoveObjectBlock(self, key, nil);
}

- (void)trimMemoryToDate:(NSDate *)trimDate
{
    [self lockForReading];
        NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
        NSDictionary *dates = [_dates copy];
    [self unlockForReading];
    
    for (NSString *key in keysSortedByDate) { // oldest objects first
        NSDate *accessDate = [dates objectForKey:key];
        if (!accessDate)
            continue;
        
        if ([accessDate compare:trimDate] == NSOrderedAscending) { // older than trim date
            [self removeObjectAndExecuteBlocksForKey:key];
        } else {
            break;
        }
    }
}

- (void)trimToCostLimit:(NSUInteger)limit
{
    [self lockForReading];
        NSUInteger totalCost = _totalCost;
        NSArray *keysSortedByCost = [_costs keysSortedByValueUsingSelector:@selector(compare:)];
    [self unlockForReading];
    
    if (totalCost <= limit) {
        return;
    }

    for (NSString *key in [keysSortedByCost reverseObjectEnumerator]) { // costliest objects first
        [self removeObjectAndExecuteBlocksForKey:key];

        [self lockForReading];
            NSUInteger totalCost = _totalCost;
        [self unlockForReading];
        
        if (totalCost <= limit)
            break;
    }
}

- (void)trimToCostLimitByDate:(NSUInteger)limit
{
    [self lockForReading];
        NSUInteger totalCost = _totalCost;
        NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
    [self unlockForReading];
    
    if (totalCost <= limit)
        return;

    for (NSString *key in keysSortedByDate) { // oldest objects first
        [self removeObjectAndExecuteBlocksForKey:key];

        [self lockForReading];
            NSUInteger totalCost = _totalCost;
        [self unlockForReading];
        if (totalCost <= limit)
            break;
    }
}

- (void)trimToAgeLimitRecursively
{
    [self lockForReading];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlockForReading];
    
    if (ageLimit == 0.0)
        return;

    NSDate *date = [[NSDate alloc] initWithTimeIntervalSinceNow:-ageLimit];
    
    [self trimMemoryToDate:date];
    
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_time_t time = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ageLimit * NSEC_PER_SEC));
    dispatch_after(time, _queue, ^(void){
        TMMemoryCache *strongSelf = weakSelf;
        if (!strongSelf)
            return;
        
        [strongSelf trimToAgeLimitRecursively];
    });
}

#pragma mark - Public Asynchronous Methods -

- (void)objectForKey:(NSString *)key block:(TMMemoryCacheObjectBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        id object = [self objectForKey:key];
        
        if (block)
            block(strongSelf, key, object);
    });
}

- (void)setObject:(id)object forKey:(NSString *)key block:(TMMemoryCacheObjectBlock)block
{
    [self setObject:object forKey:key withCost:0 block:block];
}

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost block:(TMMemoryCacheObjectBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self setObject:object forKey:key withCost:cost];
        
        if (block)
            block(strongSelf, key, object);
    });
}

- (void)removeObjectForKey:(NSString *)key block:(TMMemoryCacheObjectBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self removeObjectForKey:key];
        
        if (block)
            block(strongSelf, key, nil);
    });
}

- (void)trimToDate:(NSDate *)trimDate block:(TMMemoryCacheBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self trimToDate:trimDate];
        
        if (block)
            block(strongSelf);
    });
}

- (void)trimToCost:(NSUInteger)cost block:(TMMemoryCacheBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self trimToCost:cost];
        
        if (block)
            block(strongSelf);
    });
}

- (void)trimToCostByDate:(NSUInteger)cost block:(TMMemoryCacheBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self trimToCostByDate:cost];
        
        if (block)
            block(strongSelf);
    });
}

- (void)removeAllObjects:(TMMemoryCacheBlock)block
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self removeAllObjects];
        
        if (block)
            block(strongSelf);
    });
}

- (void)enumerateObjectsWithBlock:(TMMemoryCacheObjectBlock)block completionBlock:(TMMemoryCacheBlock)completionBlock
{
    __weak TMMemoryCache *weakSelf = self;
    
    dispatch_async(_queue, ^{
        TMMemoryCache *strongSelf = weakSelf;
        [self enumerateObjectsWithBlock:block];
        
        if (completionBlock)
            completionBlock(strongSelf);
    });
}

#pragma mark - Public Synchronous Methods -

- (id)objectForKey:(NSString *)key
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key)
        return nil;
    
    [self lockForReading];
        id object = [_dictionary objectForKey:key];
    [self unlockForReading];
        
    if (object) {
        [self lockForWriting];
            [_dates setObject:now forKey:key];
        [self unlockForWriting];
    }

    return object;
}

- (void)setObject:(id)object forKey:(NSString *)key
{
    [self setObject:object forKey:key withCost:0];
}

- (void)setObject:(id)object forKey:(NSString *)key withCost:(NSUInteger)cost
{
    NSDate *now = [[NSDate alloc] init];
    
    if (!key || !object)
        return;
    
    [self lockForReading];
        TMMemoryCacheObjectBlock willAddObjectBlock = _willAddObjectBlock;
        TMMemoryCacheObjectBlock didAddObjectBlock = _didAddObjectBlock;
        NSUInteger costLimit = _costLimit;
    [self unlockForReading];
    
    if (willAddObjectBlock)
        willAddObjectBlock(self, key, object);
    
    [self lockForWriting];
        [_dictionary setObject:object forKey:key];
        [_dates setObject:now forKey:key];
        [_costs setObject:@(cost) forKey:key];
        
        _totalCost += cost;
    [self unlockForWriting];
    
    if (didAddObjectBlock)
        didAddObjectBlock(self, key, object);
    
    if (costLimit > 0)
        [self trimToCostByDate:costLimit];
}

- (void)removeObjectForKey:(NSString *)key
{
    if (!key)
        return;
    
    [self removeObjectAndExecuteBlocksForKey:key];
}

- (void)trimToDate:(NSDate *)trimDate
{
    if (!trimDate)
        return;
    
    if ([trimDate isEqualToDate:[NSDate distantPast]]) {
        [self removeAllObjects];
        return;
    }
    
    [self trimMemoryToDate:trimDate];
}

- (void)trimToCost:(NSUInteger)cost
{
    [self trimToCostLimit:cost];
}

- (void)trimToCostByDate:(NSUInteger)cost
{
    [self trimToCostLimitByDate:cost];
}

- (void)removeAllObjects
{
    [self lockForReading];
        TMMemoryCacheBlock willRemoveAllObjectsBlock = _willRemoveAllObjectsBlock;
        TMMemoryCacheBlock didRemoveAllObjectsBlock = _didRemoveAllObjectsBlock;
    [self unlockForReading];
    
    if (willRemoveAllObjectsBlock)
        willRemoveAllObjectsBlock(self);
    
    [self lockForWriting];
        [_dictionary removeAllObjects];
        [_dates removeAllObjects];
        [_costs removeAllObjects];
    
        _totalCost = 0;
    [self unlockForWriting];
    
    if (didRemoveAllObjectsBlock)
        didRemoveAllObjectsBlock(self);
    
}

- (void)enumerateObjectsWithBlock:(TMMemoryCacheObjectBlock)block
{
    if (!block)
        return;
    
    [self lockForReading];
        NSArray *keysSortedByDate = [_dates keysSortedByValueUsingSelector:@selector(compare:)];
        
        for (NSString *key in keysSortedByDate) {
            block(self, key, [_dictionary objectForKey:key]);
        }
    [self unlockForReading];
}

#pragma mark - Public Thread Safe Accessors -

- (TMMemoryCacheObjectBlock)willAddObjectBlock
{
    [self lockForReading];
        TMMemoryCacheObjectBlock block = _willAddObjectBlock;
    [self unlockForReading];

    return block;
}

- (void)setWillAddObjectBlock:(TMMemoryCacheObjectBlock)block
{
    [self lockForWriting];
        _willAddObjectBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheObjectBlock)willRemoveObjectBlock
{
    [self lockForReading];
        TMMemoryCacheObjectBlock block = _willRemoveObjectBlock;
    [self unlockForReading];

    return block;
}

- (void)setWillRemoveObjectBlock:(TMMemoryCacheObjectBlock)block
{
    [self lockForWriting];
        _willRemoveObjectBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheBlock)willRemoveAllObjectsBlock
{
    [self lockForReading];
        TMMemoryCacheBlock block = _willRemoveAllObjectsBlock;
    [self unlockForReading];

    return block;
}

- (void)setWillRemoveAllObjectsBlock:(TMMemoryCacheBlock)block
{
    [self lockForWriting];
        _willRemoveAllObjectsBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheObjectBlock)didAddObjectBlock
{
    [self lockForReading];
        TMMemoryCacheObjectBlock block = _didAddObjectBlock;
    [self unlockForReading];

    return block;
}

- (void)setDidAddObjectBlock:(TMMemoryCacheObjectBlock)block
{
    [self lockForWriting];
        _didAddObjectBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheObjectBlock)didRemoveObjectBlock
{
    [self lockForReading];
        TMMemoryCacheObjectBlock block = _didRemoveObjectBlock;
    [self unlockForReading];

    return block;
}

- (void)setDidRemoveObjectBlock:(TMMemoryCacheObjectBlock)block
{
    [self lockForWriting];
        _didRemoveObjectBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheBlock)didRemoveAllObjectsBlock
{
    [self lockForReading];
        TMMemoryCacheBlock block = _didRemoveAllObjectsBlock;
    [self unlockForReading];

    return block;
}

- (void)setDidRemoveAllObjectsBlock:(TMMemoryCacheBlock)block
{
    [self lockForWriting];
        _didRemoveAllObjectsBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheBlock)didReceiveMemoryWarningBlock
{
    [self lockForReading];
        TMMemoryCacheBlock block = _didReceiveMemoryWarningBlock;
    [self unlockForReading];

    return block;
}

- (void)setDidReceiveMemoryWarningBlock:(TMMemoryCacheBlock)block
{
    [self lockForWriting];
        _didReceiveMemoryWarningBlock = [block copy];
    [self unlockForWriting];
}

- (TMMemoryCacheBlock)didEnterBackgroundBlock
{
    [self lockForReading];
        TMMemoryCacheBlock block = _didEnterBackgroundBlock;
    [self unlockForReading];

    return block;
}

- (void)setDidEnterBackgroundBlock:(TMMemoryCacheBlock)block
{
    [self lockForWriting];
        _didEnterBackgroundBlock = [block copy];
    [self unlockForWriting];
}

- (NSTimeInterval)ageLimit
{
    [self lockForReading];
        NSTimeInterval ageLimit = _ageLimit;
    [self unlockForReading];
    
    return ageLimit;
}

- (void)setAgeLimit:(NSTimeInterval)ageLimit
{
    [self lockForWriting];
        _ageLimit = ageLimit;
    [self unlockForWriting];
    
    [self trimToAgeLimitRecursively];
}

- (NSUInteger)costLimit
{
    [self lockForReading];
        NSUInteger costLimit = _costLimit;
    [self unlockForReading];

    return costLimit;
}

- (void)setCostLimit:(NSUInteger)costLimit
{
    [self lockForWriting];
        _costLimit = costLimit;
    [self unlockForWriting];

    if (costLimit > 0)
        [self trimToCostLimitByDate:costLimit];
}

- (NSUInteger)totalCost
{
    [self lockForReading];
        NSUInteger cost = _totalCost;
    [self unlockForReading];
    
    return cost;
}

- (void)lockForReading
{
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
}

- (void)unlockForReading
{
    dispatch_semaphore_signal(_lock);
}

- (void)lockForWriting
{
    dispatch_semaphore_wait(_lock, DISPATCH_TIME_FOREVER);
}

- (void)unlockForWriting
{
    dispatch_semaphore_signal(_lock);
}

@end
