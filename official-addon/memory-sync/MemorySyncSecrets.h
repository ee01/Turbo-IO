#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol TIOMemorySecretStore <NSObject>
- (BOOL)saveToken:(NSString *)token error:(NSError **)error;
- (nullable NSString *)loadToken:(NSError **)error;
- (BOOL)clear:(NSError **)error;
@end

@interface TIOMemoryFileSecretStore : NSObject <TIOMemorySecretStore>
- (instancetype)initWithDirectory:(NSURL *)directory;
@end

@interface TIOMemoryKeychainSecretStore : NSObject <TIOMemorySecretStore>
@end

NS_ASSUME_NONNULL_END
