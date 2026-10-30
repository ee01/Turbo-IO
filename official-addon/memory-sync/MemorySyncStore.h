#import <Foundation/Foundation.h>
#import "MemorySyncProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface TIOMemorySyncStore : NSObject
- (nullable instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error;
- (nullable NSDictionary *)recordText:(NSString *)text round:(nullable NSString *)round role:(NSString *)role at:(NSDate *)date generation:(uint64_t)generation applyUploadPolicy:(BOOL)policy error:(NSError **)error;
- (BOOL)setCaptureEnabled:(BOOL)enabled error:(NSError **)error;
- (BOOL)grantUploadConsent:(NSError **)error;
- (BOOL)setUploadPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)pairOrigin:(NSString *)origin error:(NSError **)error;
- (BOOL)setCompatibilityPaused:(BOOL)paused error:(NSError **)error;
- (BOOL)setSourcePaused:(BOOL)paused error:(NSError **)error;
- (BOOL)authorizeHistoricalUpload:(NSError **)error;
- (uint64_t)generation;
- (BOOL)captureEnabled;
- (NSString *)sessionId;
- (NSString *)sourceId;
- (nullable NSArray<NSDictionary *> *)snapshot:(NSError **)error;
- (NSDictionary *)status;
- (BOOL)recover:(NSError **)error;
- (NSArray<NSDictionary *> *)uploadCandidatesAt:(NSDate *)now limit:(NSUInteger)limit;
- (NSArray<NSDictionary *> *)resumableBatchesAt:(NSDate *)now;
- (BOOL)beginBatch:(NSString *)batchId items:(NSArray<NSDictionary *> *)items fileURL:(NSURL *)file hash:(NSString *)hash error:(NSError **)error;
- (BOOL)markSubmittedBatch:(NSString *)batchId taskIdentifier:(nullable NSString *)task error:(NSError **)error;
- (BOOL)acknowledgeBatch:(NSString *)batchId ack:(NSDictionary *)ack error:(NSError **)error;
- (BOOL)failBatch:(NSString *)batchId code:(NSString *)code retryAt:(nullable NSDate *)retryAt authPause:(BOOL)authPause error:(NSError **)error;
- (BOOL)markEventError:(NSString *)eventId revision:(uint64_t)revision code:(NSString *)code error:(NSError **)error;
- (void)reconcileTasks:(NSDictionary<NSString *, NSString *> *)batchToTask;
@end

NS_ASSUME_NONNULL_END
