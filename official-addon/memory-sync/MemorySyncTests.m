#import "MemorySyncProtocol.h"
#import "MemorySyncStore.h"
#import "MemorySyncSecrets.h"
#import "MemoryUploadCoordinator.h"
#import "MemorySyncLifecycle.h"
#import "MemorySyncRuntime.h"
#include <assert.h>

static NSURL *TempDir(void) {
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

@interface HoldingTransport : NSObject <TIOMemoryUploadTransport>
@property NSInteger status;
@property BOOL mismatch;
@property NSMutableArray *pending;
@property NSUInteger calls;
@end
@implementation HoldingTransport
- (instancetype)init { if ((self = [super init])) { _pending = [NSMutableArray array]; _status = 200; } return self; }
- (NSDictionary *)ackForFile:(NSURL *)file source:(NSString *)sourceId batch:(NSString *)batchId hash:(NSString *)hash {
    NSString *text = [[NSString alloc] initWithData:[NSData dataWithContentsOfURL:file] encoding:NSUTF8StringEncoding];
    NSMutableArray *events = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *item = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (item[@"eventId"]) [events addObject:@{@"eventId": item[@"eventId"], @"revision": item[@"revision"], @"seq": @1}];
    }
    return @{@"schemaVersion": @1, @"sourceId": sourceId, @"batchId": batchId, @"payloadHash": hash, @"committedAt": @"2026-10-09T12:00:00Z", @"events": events};
}
- (void)uploadFile:(NSURL *)file source:(NSString *)sourceId batch:(NSString *)batchId hash:(NSString *)hash completion:(void (^)(NSInteger, NSDictionary *, NSString *))completion {
    self.calls++;
    NSDictionary *ack = [self ackForFile:file source:sourceId batch:batchId hash:hash];
    if (self.status == 0 && !self.mismatch) {
        [self.pending addObject:[^{ completion(200, ack, nil); } copy]];
        return;
    }
    if (self.mismatch) completion(200, @{@"schemaVersion": @1, @"sourceId": sourceId, @"batchId": batchId, @"payloadHash": @"deadbeef", @"committedAt": @"2026-10-09T12:00:00Z", @"events": @[]}, nil);
    else completion(self.status, self.status == 200 ? ack : nil, nil);
}
- (void)releaseAll { for (void (^block)(void) in self.pending) block(); [self.pending removeAllObjects]; }
@end

static void PrepareUpload(TIOMemorySyncStore *store) {
    NSError *error = nil;
    assert([store setCaptureEnabled:YES error:&error]);
    assert([store grantUploadConsent:&error]);
    assert([store pairOrigin:@"https://mac.example" error:&error]);
}

int main(void) { @autoreleasepool {
    NSData *fixture = [NSData dataWithContentsOfFile:@"memory-sync/testdata/batch-one.jsonl"];
    NSString *expected = [[NSString stringWithContentsOfFile:@"memory-sync/testdata/batch-one.sha256" encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    assert(fixture.length && [TIOMemorySyncSHA256(fixture) isEqual:expected]);
    assert(TIOMemorySyncOriginValid(@"https://mac.example"));
    assert(!TIOMemorySyncOriginValid(@"http://mac.example"));
    assert(!TIOMemorySyncOriginValid(@"https://user:pass@mac.example"));
    assert(!TIOMemorySyncOriginValid(@"https://mac.example/v1"));
    assert(TIOMemorySyncURLTriggersSync([NSURL URLWithString:@"turboio-memory://sync-now"]));
    assert(!TIOMemorySyncURLTriggersSync([NSURL URLWithString:@"turboio-memory://sync-now?token=secret"]));
    assert(!TIOMemorySyncURLTriggersSync([NSURL URLWithString:@"turboio-memory://sync-now/extra"]));
    assert(TIOMemorySyncIsOwnSession(TIOMemorySyncSessionIdentifier));
    assert(!TIOMemorySyncIsOwnSession(@"com.apple.other"));
    NSDictionary *query = TIOMemorySyncKeychainAddQuery(@"io.turboio.memory-sync", @"ms_test");
    assert([query[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]);
    assert([query[(__bridge id)kSecAttrSynchronizable] isEqual:@NO]);

    __block BOOL handled = NO;
    TIOMemorySyncLifecycle *life = [TIOMemorySyncLifecycle new];
    life.handler = ^(void (^completion)(void)) { handled = YES; completion(); };
    assert(![life handleIdentifier:@"other" completion:^{ assert(NO); }]);
    assert(!handled);
    assert([life handleIdentifier:TIOMemorySyncSessionIdentifier completion:^{}]);
    assert(handled);

    NSURL *dir = TempDir();
    TIOMemorySyncStore *store = [[TIOMemorySyncStore alloc] initWithDirectory:dir error:nil];
    NSString *source = store.sourceId;
    assert([store setCaptureEnabled:YES error:nil]);
    NSString *session = store.sessionId;
    for (NSInteger i = 0; i < 10; i++) {
        store = [[TIOMemorySyncStore alloc] initWithDirectory:dir error:nil];
        assert(store.captureEnabled && [store.sourceId isEqual:source] && ![store.sessionId isEqual:session]);
        session = store.sessionId;
    }
    assert([store setCaptureEnabled:NO error:nil]);
    for (NSInteger i = 0; i < 10; i++) {
        store = [[TIOMemorySyncStore alloc] initWithDirectory:dir error:nil];
        assert(!store.captureEnabled && [store.sourceId isEqual:source]);
    }

    assert([store setCaptureEnabled:YES error:nil]);
    uint64_t generation = store.generation;
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
    NSDictionary *saved = [store recordText:@"第一句" round:@"round" role:@"0" at:now generation:generation applyUploadPolicy:YES error:nil];
    assert([saved[@"accepted"] boolValue] && ![saved[@"queued"] boolValue]);
    NSDictionary *duplicate = [store recordText:@"第一句" round:@"round" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([duplicate[@"duplicate"] boolValue] && [duplicate[@"revision"] integerValue] == 1);
    NSDictionary *revised = [store recordText:@"修订" round:@"round" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([revised[@"revision"] integerValue] == 2);
    NSDictionary *other = [store recordText:@"修订" round:@"other" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([other[@"accepted"] boolValue] && ![other[@"eventId"] isEqual:revised[@"eventId"]]);
    assert([store setCaptureEnabled:NO error:nil]);
    NSDictionary *stale = [store recordText:@"晚到" round:@"late" role:@"0" at:now generation:generation applyUploadPolicy:YES error:nil];
    assert(![stale[@"accepted"] boolValue] && [stale[@"reason"] isEqual:@"generation"] && [store.status[@"rejectedStale"] unsignedIntegerValue] == 1);
    assert([store.status[@"recordCount"] integerValue] == 2);
    assert(![store.status[@"running"] boolValue]);

    assert([store grantUploadConsent:nil]);
    NSDictionary *future = [store recordText:@"同意之后" round:@"after" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert(![future[@"accepted"] boolValue]);
    assert([store setCaptureEnabled:YES error:nil]);
    future = [store recordText:@"同意之后" round:@"after" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([future[@"accepted"] boolValue] && ![future[@"queued"] boolValue]);
    assert([store pairOrigin:@"https://mac.example" error:nil]);
    NSDictionary *queued = [store recordText:@"可以上传" round:@"upload" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([queued[@"queued"] boolValue]);
    assert([store uploadCandidatesAt:now limit:10].count == 1);
    assert([store authorizeHistoricalUpload:nil]);
    assert([store uploadCandidatesAt:now limit:20].count >= 2);
    assert([store setUploadPaused:YES error:nil]);
    assert([store uploadCandidatesAt:now limit:20].count == 0);
    assert([store.status[@"pendingCount"] integerValue] >= 2);
    assert([store setUploadPaused:NO error:nil]);
    assert([store pairOrigin:@"https://other.example" error:nil]);
    assert([store.status[@"heldForOtherTarget"] integerValue] >= 1);
    NSDictionary *moved = [store recordText:@"新目标" round:@"new-target" role:@"0" at:now generation:store.generation applyUploadPolicy:YES error:nil];
    assert([moved[@"queued"] boolValue]);

    NSURL *migrationDir = TempDir();
    NSString *legacy = @"[{\"id\":\"old-1|0\",\"role\":\"0\",\"text\":\"旧副本\",\"at\":\"2026-10-09T12:00:00Z\"}]";
    NSURL *legacyFile = [migrationDir URLByAppendingPathComponent:@"final-transcripts.json"];
    assert([legacy writeToURL:legacyFile atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    TIOMemorySyncStore *migrated = [[TIOMemorySyncStore alloc] initWithDirectory:migrationDir error:nil];
    assert([[[migrated snapshot:nil] firstObject][@"text"] isEqual:@"旧副本"]);
    assert([NSFileManager.defaultManager fileExistsAtPath:legacyFile.path]);
    assert([migrated uploadCandidatesAt:now limit:10].count == 0);
    NSData *original = [NSData dataWithContentsOfURL:legacyFile];
    NSURL *badDir = TempDir();
    NSURL *badFile = [badDir URLByAppendingPathComponent:@"final-transcripts.json"];
    assert([@"not-json" writeToURL:badFile atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    TIOMemorySyncStore *blocked = [[TIOMemorySyncStore alloc] initWithDirectory:badDir error:nil];
    assert([blocked.status[@"migrationBlocked"] boolValue]);
    assert([blocked setCaptureEnabled:YES error:nil]);
    NSDictionary *refused = [blocked recordText:@"不该写入" round:@"x" role:@"0" at:now generation:blocked.generation applyUploadPolicy:YES error:nil];
    assert(![refused[@"accepted"] boolValue]);
    assert([[NSData dataWithContentsOfURL:badFile] isEqual:[@"not-json" dataUsingEncoding:NSUTF8StringEncoding]]);
    (void)original;

    NSMutableArray *many = [NSMutableArray array];
    for (NSInteger i = 0; i < 5; i++) {
        [many addObject:@{@"schemaVersion": @1, @"sourceId": @"s", @"eventId": [NSString stringWithFormat:@"e%ld", (long)i], @"revision": @1, @"sessionId": @"s", @"receivedAt": @"2026-10-09T12:00:00Z", @"updatedAt": @"2026-10-09T12:00:00Z", @"role": @"0", @"text": @"12345", @"textHash": @"x"}];
    }
    NSDictionary *oversized = nil;
    NSArray *two = TIOMemorySyncNextBatch(@"s", @"batch-size-placeholder-000000000000", many, 2, TIOMemorySyncMaxBatchBytes, &oversized);
    assert(two.count == 2 && !oversized);
    NSArray *none = TIOMemorySyncNextBatch(@"s", @"batch-size-placeholder-000000000000", many, 100, 20, &oversized);
    assert(!none.count && oversized);

    HoldingTransport *transport = [HoldingTransport new];
    transport.status = 500;
    __block NSDate *clock = [NSDate date];
    TIOMemoryUploadCoordinator *coordinator = [[TIOMemoryUploadCoordinator alloc] initWithStore:store directory:dir transport:transport now:^NSDate *{ return clock; }];
    [coordinator schedule];
    assert(transport.calls >= 1);
    NSUInteger afterFailure = transport.calls;
    clock = [clock dateByAddingTimeInterval:1];
    [coordinator schedule];
    assert(transport.calls == afterFailure);
    clock = [clock dateByAddingTimeInterval:5];
    transport.status = 200;
    [coordinator schedule];
    assert(transport.calls > afterFailure);
    assert(coordinator.inFlight == 0);

    NSURL *uploadDir = TempDir();
    TIOMemorySyncStore *uploadStore = [[TIOMemorySyncStore alloc] initWithDirectory:uploadDir error:nil];
    PrepareUpload(uploadStore);
    NSMutableString *wide = [NSMutableString string];
    for (NSInteger n = 0; n < 20000; n++) [wide appendString:@"字"];
    for (NSInteger i = 0; i < 20; i++) {
        NSDictionary *row = [uploadStore recordText:wide round:[NSString stringWithFormat:@"wide-%ld", (long)i] role:@"0" at:now generation:uploadStore.generation applyUploadPolicy:YES error:nil];
        assert([row[@"queued"] boolValue]);
    }
    HoldingTransport *holding = [HoldingTransport new];
    holding.status = 0;
    TIOMemoryUploadCoordinator *limited = [[TIOMemoryUploadCoordinator alloc] initWithStore:uploadStore directory:uploadDir transport:holding now:nil];
    [limited schedule];
    assert(holding.calls == 2 && limited.inFlight == 2);
    holding.status = 200;
    [holding releaseAll];
    assert(holding.calls == 3 && limited.inFlight == 0);
    assert([uploadStore.status[@"pendingCount"] integerValue] == 0);

    NSURL *mismatchDir = TempDir();
    TIOMemorySyncStore *mismatchStore = [[TIOMemorySyncStore alloc] initWithDirectory:mismatchDir error:nil];
    PrepareUpload(mismatchStore);
    assert([[mismatchStore recordText:@"冲突" round:@"c" role:@"0" at:now generation:mismatchStore.generation applyUploadPolicy:YES error:nil][@"queued"] boolValue]);
    HoldingTransport *badAck = [HoldingTransport new];
    badAck.mismatch = YES;
    TIOMemoryUploadCoordinator *mismatchCoordinator = [[TIOMemoryUploadCoordinator alloc] initWithStore:mismatchStore directory:mismatchDir transport:badAck now:nil];
    [mismatchCoordinator schedule];
    assert([mismatchStore.status[@"lastError"] isEqual:@"ack_mismatch"]);
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtURL:[mismatchDir URLByAppendingPathComponent:@"outgoing"] includingPropertiesForKeys:nil options:0 error:nil] count] == 1);
    badAck.mismatch = NO;
    badAck.status = 404;
    [mismatchCoordinator schedule];
    assert([[NSFileManager.defaultManager contentsOfDirectoryAtURL:[mismatchDir URLByAppendingPathComponent:@"outgoing"] includingPropertiesForKeys:nil options:0 error:nil] count] == 1);

    TIOMemoryFileSecretStore *secrets = [[TIOMemoryFileSecretStore alloc] initWithDirectory:dir];
    HoldingTransport *runtimeTransport = [HoldingTransport new];
    runtimeTransport.status = 200;
    TIOMemorySyncRuntime *runtime = [[TIOMemorySyncRuntime alloc] initWithDirectory:TempDir() transport:runtimeTransport secrets:secrets error:nil];
    assert([runtime setCaptureEnabled:YES error:nil]);
    [runtime acceptFinalText:@"先到" round:@"queued" role:@"0" receivedAt:now];
    assert([runtime setCaptureEnabled:NO error:nil]);
    [runtime acceptFinalText:@"后到" round:@"dropped" role:@"0" receivedAt:now];
    [runtime flush];
    NSArray *rows = [runtime.store snapshot:nil];
    assert(rows.count == 1 && [rows[0][@"text"] isEqual:@"先到"]);
    assert([runtime pairOrigin:@"https://mac.example" token:@"ms_local" error:nil]);
    assert([runtime grantUploadConsent:nil]);
    assert([runtime setCaptureEnabled:YES error:nil]);
    [runtime acceptFinalText:@"同步" round:@"sync" role:@"0" receivedAt:now];
    [runtime flush];
    assert([runtime handleURL:[NSURL URLWithString:@"turboio-memory://sync-now?text=no"]] == NO);
    assert(runtimeTransport.calls == 0);
    assert([runtime handleURL:[NSURL URLWithString:@"turboio-memory://sync-now"]]);
    [runtime flush];
    assert(runtimeTransport.calls == 1);

    NSLog(@"PASS: memory settings, migration, batches, ack mismatch, retry and URL sync. Synthetic data only.");
} return 0; }
