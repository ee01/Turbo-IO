#import "MemorySyncSecrets.h"
#import "MemorySyncProtocol.h"
#import <Security/Security.h>

@implementation TIOMemoryFileSecretStore {
    NSURL *_file;
}
- (instancetype)initWithDirectory:(NSURL *)directory {
    if (!(self = [super init])) return nil;
    _file = [directory URLByAppendingPathComponent:@"pairing-token"];
    return self;
}
- (BOOL)saveToken:(NSString *)token error:(NSError **)error {
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || token.length > 256) {
        if (error) *error = [NSError errorWithDomain:TIOMemorySyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"配对令牌无效"}];
        return NO;
    }
    BOOL ok = [data writeToURL:_file options:NSDataWritingAtomic error:error];
    if (ok) [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:_file.path error:nil];
    return ok;
}
- (NSString *)loadToken:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfURL:_file options:0 error:error];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
- (BOOL)clear:(NSError **)error {
    return [NSFileManager.defaultManager removeItemAtURL:_file error:error] || ![NSFileManager.defaultManager fileExistsAtPath:_file.path];
}
@end

@implementation TIOMemoryKeychainSecretStore
static NSString *const Service = @"io.turboio.memory-sync";
- (NSDictionary *)match {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: Service,
        (__bridge id)kSecAttrAccount: @"pairing-token"
    };
}
- (BOOL)saveToken:(NSString *)token error:(NSError **)error {
    if (!token.length || token.length > 256) return NO;
    NSMutableDictionary *query = [TIOMemorySyncKeychainAddQuery(Service, token) mutableCopy];
    SecItemDelete((__bridge CFDictionaryRef)self.match);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess && error) *error = [NSError errorWithDomain:TIOMemorySyncErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"钥匙串没有保存配对令牌"}];
    return status == errSecSuccess;
}
- (NSString *)loadToken:(NSError **)error {
    NSMutableDictionary *query = [self.match mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:TIOMemorySyncErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: @"没有可读的配对令牌"}];
        return nil;
    }
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
- (BOOL)clear:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)self.match);
    return status == errSecSuccess || status == errSecItemNotFound;
}
@end
