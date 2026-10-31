#import "MemorySyncRuntime.h"
#import "MemorySyncProtocol.h"

@interface TIOMemoryURLTransport : NSObject <TIOMemoryUploadTransport, NSURLSessionDataDelegate>
- (instancetype)initWithOrigin:(NSString *(^)(void))origin token:(NSString *(^)(void))token;
- (void)handleEvents:(void (^)(void))completion;
@end

@implementation TIOMemoryURLTransport {
    NSURLSession *_session;
    NSString *(^_origin)(void);
    NSString *(^_token)(void);
    NSMutableDictionary<NSNumber *, void (^)(NSInteger, NSDictionary *, NSString *)> *_completions;
    NSMutableDictionary<NSNumber *, NSMutableData *> *_bodies;
    void (^_backgroundCompletion)(void);
}
- (instancetype)initWithOrigin:(NSString *(^)(void))origin token:(NSString *(^)(void))token {
    if (!(self = [super init])) return nil;
    _origin = [origin copy];
    _token = [token copy];
    _completions = [NSMutableDictionary dictionary];
    _bodies = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:TIOMemorySyncSessionIdentifier];
    configuration.sessionSendsLaunchEvents = YES;
    configuration.discretionary = NO;
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    return self;
}
- (void)uploadFile:(NSURL *)file source:(NSString *)sourceId batch:(NSString *)batchId hash:(NSString *)hash completion:(void (^)(NSInteger, NSDictionary *, NSString *))completion {
    NSString *origin = _origin ? _origin() : @"";
    if (!TIOMemorySyncOriginValid(origin)) {
        completion(0, nil, @"origin");
        return;
    }
    NSURL *url = [NSURL URLWithString:[origin stringByAppendingString:@"/v1/memory/batches"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:[@"Bearer " stringByAppendingString:(_token ? _token() : @"") ?: @""] forHTTPHeaderField:@"Authorization"];
    [request setValue:sourceId forHTTPHeaderField:@"X-Memory-Source-Id"];
    [request setValue:batchId forHTTPHeaderField:@"X-Memory-Batch-Id"];
    [request setValue:hash forHTTPHeaderField:@"X-Memory-Payload-Hash"];
    NSURLSessionUploadTask *task = [_session uploadTaskWithRequest:request fromFile:file];
    task.taskDescription = batchId;
    @synchronized (self) {
        if (completion) _completions[@(task.taskIdentifier)] = [completion copy];
        _bodies[@(task.taskIdentifier)] = [NSMutableData data];
    }
    [task resume];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @synchronized (self) { [_bodies[@(task.taskIdentifier)] appendData:data]; }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSData *body = nil;
    void (^completion)(NSInteger, NSDictionary *, NSString *) = nil;
    @synchronized (self) {
        body = _bodies[@(task.taskIdentifier)];
        completion = _completions[@(task.taskIdentifier)];
        [_bodies removeObjectForKey:@(task.taskIdentifier)];
        [_completions removeObjectForKey:@(task.taskIdentifier)];
    }
    NSInteger status = error ? 0 : [(NSHTTPURLResponse *)task.response statusCode];
    NSDictionary *ack = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
    if (completion) completion(status, [ack isKindOfClass:NSDictionary.class] ? ack : nil, error ? @"network" : nil);
}
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    void (^completion)(void) = nil;
    @synchronized (self) {
        completion = _backgroundCompletion;
        _backgroundCompletion = nil;
    }
    if (completion) completion();
}
- (void)handleEvents:(void (^)(void))completion {
    @synchronized (self) { _backgroundCompletion = [completion copy]; }
    [_session getAllTasksWithCompletionHandler:^(NSArray *tasks) {
        if (!tasks.count) {
            void (^saved)(void) = nil;
            @synchronized (self) {
                saved = self->_backgroundCompletion;
                self->_backgroundCompletion = nil;
            }
            if (saved) saved();
        }
    }];
}
@end

@implementation TIOMemorySyncRuntime {
    TIOMemorySyncStore *_store;
    id<TIOMemorySecretStore> _secrets;
    TIOMemoryUploadCoordinator *_coordinator;
    TIOMemoryURLTransport *_network;
    dispatch_queue_t _queue;
    NSObject *_gate;
    uint64_t _generation;
}
- (instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error {
    return [self initWithDirectory:directory transport:nil secrets:[[TIOMemoryKeychainSecretStore alloc] init] error:error];
}
- (instancetype)initWithDirectory:(NSURL *)directory transport:(id<TIOMemoryUploadTransport>)transport secrets:(id<TIOMemorySecretStore>)secrets error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _store = [[TIOMemorySyncStore alloc] initWithDirectory:directory error:error];
    if (!_store) return nil;
    _secrets = secrets;
    _queue = dispatch_queue_create("io.turboio.memory.sync", DISPATCH_QUEUE_SERIAL);
    _gate = [NSObject new];
    _generation = _store.generation;
    if (!transport) {
        __weak typeof(self) weak = self;
        _network = [[TIOMemoryURLTransport alloc] initWithOrigin:^NSString *{
            return weak.store.status[@"origin"] ?: @"";
        } token:^NSString *{
            return [weak loadToken];
        }];
        transport = _network;
    }
    _coordinator = [[TIOMemoryUploadCoordinator alloc] initWithStore:_store directory:directory transport:transport now:nil];
    return self;
}
- (TIOMemorySyncStore *)store { return _store; }
- (uint64_t)generation { @synchronized (_gate) { return _generation; } }
- (BOOL)setCaptureEnabled:(BOOL)enabled error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *local = nil;
    dispatch_sync(_queue, ^{
        ok = [self->_store setCaptureEnabled:enabled error:&local];
        @synchronized (self->_gate) { self->_generation = self->_store.generation; }
    });
    if (error) *error = local;
    return ok;
}
- (BOOL)grantUploadConsent:(NSError **)error { return [_store grantUploadConsent:error]; }
- (BOOL)setUploadPaused:(BOOL)paused error:(NSError **)error { return [_store setUploadPaused:paused error:error]; }
- (BOOL)setCompatibilityPaused:(BOOL)paused error:(NSError **)error { return [_store setCompatibilityPaused:paused error:error]; }
- (BOOL)authorizeHistoricalUpload:(NSError **)error { return [_store authorizeHistoricalUpload:error]; }
- (BOOL)pairOrigin:(NSString *)origin token:(NSString *)token error:(NSError **)error {
    if (![_secrets saveToken:token error:error]) return NO;
    if (![_store pairOrigin:origin error:error]) return NO;
    return YES;
}
- (void)acceptFinalText:(NSString *)text round:(NSString *)round role:(NSString *)role receivedAt:(NSDate *)date {
    uint64_t generation = self.generation;
    dispatch_async(_queue, ^{
        [self->_store recordText:text round:round role:role at:date generation:generation applyUploadPolicy:YES error:nil];
    });
}
- (void)flush { dispatch_sync(_queue, ^{}); }
- (void)syncNow { dispatch_async(_queue, ^{ [self->_coordinator schedule]; }); }
- (BOOL)handleURL:(NSURL *)url {
    if (!TIOMemorySyncURLTriggersSync(url)) return NO;
    [self syncNow];
    return YES;
}
- (NSDictionary *)status { return _store.status; }
- (NSString *)loadToken { return [_secrets loadToken:nil] ?: @""; }
- (void)handleBackgroundEvents:(void (^)(void))completion {
    if (_network) [_network handleEvents:completion];
    else if (completion) completion();
}
@end
