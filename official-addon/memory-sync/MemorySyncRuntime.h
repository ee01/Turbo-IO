#import <Foundation/Foundation.h>
#import "MemorySyncStore.h"
#import "MemoryUploadCoordinator.h"
#import "MemorySyncSecrets.h"

NS_ASSUME_NONNULL_BEGIN

@interface TIOMemorySyncRuntime : NSObject
- (nullable instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error;
- (instancetype)initWithDirectory:(NSURL *)directory transport:(nullable id<TIOMemoryUploadTransport>)transport secrets:(id<TIOMemorySecretStore>)secrets error:(NSError **)error;
- (BOOL)setCaptureEnabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)grantUploadConsent:(NSError **)error;
- (BOOL)setUploadPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)pairOrigin:(NSString *)origin token:(NSString *)token error:(NSError **)error;
- (BOOL)setCompatibilityPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)authorizeHistoricalUpload:(NSError **)error;
- (void)acceptFinalText:(NSString *)text round:(nullable NSString *)round role:(NSString *)role receivedAt:(NSDate *)date;
- (void)flush;
- (void)syncNow;
- (BOOL)handleURL:(NSURL *)url;
- (NSDictionary *)status;
- (uint64_t)generation;
- (void)handleBackgroundEvents:(void (^ _Nullable)(void))completion;
@property(nonatomic, readonly) TIOMemorySyncStore *store;
@end

NS_ASSUME_NONNULL_END
