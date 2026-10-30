#import "MemoryUploadCoordinator.h"
#import "MemorySyncProtocol.h"

@implementation TIOMemoryUploadCoordinator {
    TIOMemorySyncStore *_store;
    NSURL *_directory;
    id<TIOMemoryUploadTransport> _transport;
    NSDate *(^_now)(void);
    NSLock *_lock;
    NSMutableSet<NSString *> *_active;
    NSUInteger _inFlight;
    BOOL _scheduling;
}

- (instancetype)initWithStore:(TIOMemorySyncStore *)store directory:(NSURL *)directory transport:(id<TIOMemoryUploadTransport>)transport now:(NSDate *(^)(void))now {
    if (!(self = [super init])) return nil;
    _store = store;
    _directory = directory;
    _transport = transport;
    _now = [now copy];
    _lock = [NSLock new];
    _active = [NSMutableSet set];
    return self;
}

- (NSUInteger)inFlight { [_lock lock]; NSUInteger value = _inFlight; [_lock unlock]; return value; }

- (void)schedule {
    [_lock lock];
    if (_scheduling) { [_lock unlock]; return; }
    _scheduling = YES;
    [_lock unlock];
    [_store recover:nil];
    while (self.inFlight < TIOMemorySyncMaxConcurrentUploads) {
        if (![self startOne]) break;
    }
    [_lock lock];
    _scheduling = NO;
    [_lock unlock];
}

- (BOOL)startOne {
    NSDate *now = _now ? _now() : NSDate.date;
    for (NSDictionary *batch in [_store resumableBatchesAt:now]) {
        [_lock lock];
        BOOL already = [_active containsObject:batch[@"batchId"]];
        [_lock unlock];
        if (already) continue;
        NSURL *file = [NSURL fileURLWithPath:batch[@"filePath"] ?: @""];
        if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) {
            file = [[_directory URLByAppendingPathComponent:@"outgoing"] URLByAppendingPathComponent:[batch[@"batchId"] stringByAppendingPathExtension:@"jsonl"]];
        }
        if (!file.path.length || ![NSFileManager.defaultManager fileExistsAtPath:file.path]) continue;
        [self send:batch[@"batchId"] source:batch[@"sourceId"] file:file hash:batch[@"payloadHash"]];
        return YES;
    }
    NSString *batchId = NSUUID.UUID.UUIDString;
    NSArray *candidates = [_store uploadCandidatesAt:now limit:TIOMemorySyncMaxBatchItems];
    if (!candidates.count) return NO;
    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *item in candidates) [events addObject:item[@"event"]];
    NSDictionary *oversized = nil;
    NSString *source = _store.sourceId;
    NSArray *chosen = TIOMemorySyncNextBatch(source, batchId, events, TIOMemorySyncMaxBatchItems, TIOMemorySyncMaxBatchBytes, &oversized);
    if (oversized) {
        [_store markEventError:oversized[@"eventId"] revision:[oversized[@"revision"] unsignedLongLongValue] code:@"batch_too_large" error:nil];
        return YES;
    }
    if (!chosen.count) return NO;
    NSError *error = nil;
    NSData *body = TIOMemorySyncEncodeBatch(source, batchId, chosen, &error);
    if (!body) return NO;
    NSURL *folder = [_directory URLByAppendingPathComponent:@"outgoing" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSURL *file = [[folder URLByAppendingPathComponent:[batchId stringByAppendingPathExtension:@"jsonl"]] URLByResolvingSymlinksInPath];
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path] || ![body writeToURL:file options:NSDataWritingWithoutOverwriting error:&error]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:file.path error:nil];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *event in chosen) [items addObject:@{@"eventId": event[@"eventId"], @"revision": event[@"revision"]}];
    if (![_store beginBatch:batchId items:items fileURL:file hash:TIOMemorySyncSHA256(body) error:&error]) {
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        return NO;
    }
    [self send:batchId source:source file:file hash:TIOMemorySyncSHA256(body)];
    return YES;
}

- (void)send:(NSString *)batchId source:(NSString *)source file:(NSURL *)file hash:(NSString *)hash {
    [_lock lock];
    _inFlight++;
    [_active addObject:batchId];
    [_lock unlock];
    [_store markSubmittedBatch:batchId taskIdentifier:nil error:nil];
    __weak typeof(self) weak = self;
    [_transport uploadFile:file source:source batch:batchId hash:hash completion:^(NSInteger status, NSDictionary *ack, NSString *code) {
        [weak finishBatch:batchId file:file status:status ack:ack];
    }];
}

- (void)finishBatch:(NSString *)batchId file:(NSURL *)file status:(NSInteger)status ack:(NSDictionary *)ack {
    [_lock lock];
    BOOL active = [_active containsObject:batchId];
    if (active) {
        [_active removeObject:batchId];
        if (_inFlight) _inFlight--;
    }
    BOOL scheduling = _scheduling;
    [_lock unlock];
    if (!active) return;
    if (status == 200) {
        if ([ack isKindOfClass:NSDictionary.class] && [_store acknowledgeBatch:batchId ack:ack error:nil]) {
            [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        } else {
            [_store failBatch:batchId code:@"ack_mismatch" retryAt:nil authPause:NO error:nil];
        }
    } else if (status == 401 || status == 403) {
        [_store failBatch:batchId code:@"auth" retryAt:nil authPause:YES error:nil];
    } else if (status == 409 || status == 413 || status == 400) {
        [_store failBatch:batchId code:status == 409 ? @"conflict" : @"rejected" retryAt:nil authPause:NO error:nil];
    } else {
        NSDate *now = _now ? _now() : NSDate.date;
        [_store failBatch:batchId code:status == 404 ? @"not_ack" : @"retry" retryAt:[now dateByAddingTimeInterval:2] authPause:NO error:nil];
    }
    if (!scheduling) [self schedule];
}

@end
