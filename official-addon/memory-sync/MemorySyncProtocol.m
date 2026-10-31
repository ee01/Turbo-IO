#import "MemorySyncProtocol.h"
#import <CommonCrypto/CommonCrypto.h>

NSString *const TIOMemorySyncErrorDomain = @"TurboIOMemorySync";
NSString *const TIOMemorySyncSessionIdentifier = @"io.turboio.memory.sync.upload";
NSInteger const TIOMemorySyncSchemaVersion = 1;
NSUInteger const TIOMemorySyncMaxBatchItems = 100;
NSUInteger const TIOMemorySyncMaxBatchBytes = 512 * 1024;
NSUInteger const TIOMemorySyncMaxConcurrentUploads = 2;
NSUInteger const TIOMemorySyncMaxAttempts = 8;
NSUInteger const TIOMemorySyncMaxRecords = 20000;
NSUInteger const TIOMemorySyncMaxBytes = 32 * 1024 * 1024;

static NSError *ProtocolError(NSString *message) {
    return [NSError errorWithDomain:TIOMemorySyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"批次编码失败"}];
}

NSString *TIOMemorySyncSHA256(NSData *data) {
    if (!data || data.length > UINT32_MAX) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

NSString *TIOMemorySyncTextHash(NSString *text) {
    return TIOMemorySyncSHA256([text dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSData *JSONLine(NSDictionary *object, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:error];
    if (!data) return nil;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    return line;
}

NSData *TIOMemorySyncEncodeBatch(NSString *sourceId, NSString *batchId, NSArray<NSDictionary *> *events, NSError **error) {
    if (!sourceId.length || !batchId.length || !events.count) {
        if (error) *error = ProtocolError(@"批次缺少来源、编号或事件");
        return nil;
    }
    NSDictionary *header = @{
        @"batchId": batchId,
        @"eventCount": @(events.count),
        @"schemaVersion": @(TIOMemorySyncSchemaVersion),
        @"sourceId": sourceId,
        @"type": @"batch"
    };
    NSMutableData *body = [NSMutableData data];
    NSData *first = JSONLine(header, error);
    if (!first) return nil;
    [body appendData:first];
    for (NSDictionary *event in events) {
        NSData *line = JSONLine(event, error);
        if (!line) return nil;
        [body appendData:line];
    }
    return body;
}

NSArray<NSDictionary *> *TIOMemorySyncNextBatch(NSString *sourceId, NSString *batchId, NSArray<NSDictionary *> *events, NSUInteger maxItems, NSUInteger maxBytes, NSDictionary **oversized) {
    if (oversized) *oversized = nil;
    NSMutableArray *batch = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (batch.count >= maxItems) break;
        NSArray *trial = [batch arrayByAddingObject:event];
        NSData *encoded = TIOMemorySyncEncodeBatch(sourceId, batchId, trial, NULL);
        if (!encoded || encoded.length > maxBytes) {
            if (!batch.count && oversized) *oversized = event;
            break;
        }
        [batch addObject:event];
    }
    return batch;
}

BOOL TIOMemorySyncOriginValid(NSString *origin) {
    NSURL *url = [NSURL URLWithString:origin ?: @""];
    if (!url || ![url.scheme.lowercaseString isEqual:@"https"] || !url.host.length) return NO;
    if (url.user.length || url.password.length || url.query.length || url.fragment.length) return NO;
    if ([origin rangeOfString:@" "].location != NSNotFound || [origin rangeOfString:@"\\"].location != NSNotFound) return NO;
    NSString *canonical = [NSString stringWithFormat:@"https://%@", url.host];
    if (url.port) canonical = [canonical stringByAppendingFormat:@":%@", url.port];
    return [origin isEqual:canonical];
}

BOOL TIOMemorySyncURLTriggersSync(NSURL *url) {
    if (!url || ![url.scheme isEqual:@"turboio-memory"] || ![url.host isEqual:@"sync-now"]) return NO;
    if (url.user.length || url.password.length || url.query.length || url.fragment.length || url.path.length) return NO;
    return YES;
}

BOOL TIOMemorySyncIsOwnSession(NSString *identifier) {
    return [identifier isEqual:TIOMemorySyncSessionIdentifier];
}

NSDictionary *TIOMemorySyncKeychainAddQuery(NSString *service, NSString *token) {
    NSData *secret = [token dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service ?: @"",
        (__bridge id)kSecAttrAccount: @"pairing-token",
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecAttrSynchronizable: @NO,
        (__bridge id)kSecValueData: secret
    };
}
