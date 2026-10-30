#import <Foundation/Foundation.h>
#import "MemorySyncStore.h"

NS_ASSUME_NONNULL_BEGIN

@protocol TIOMemoryUploadTransport <NSObject>
- (void)uploadFile:(NSURL *)file source:(NSString *)sourceId batch:(NSString *)batchId hash:(NSString *)hash completion:(void (^)(NSInteger status, NSDictionary * _Nullable ack, NSString * _Nullable code))completion;
@end

@interface TIOMemoryUploadCoordinator : NSObject
@property(nonatomic, readonly) NSUInteger inFlight;
- (instancetype)initWithStore:(TIOMemorySyncStore *)store directory:(NSURL *)directory transport:(id<TIOMemoryUploadTransport>)transport now:(NSDate * _Nullable (^ _Nullable)(void))now;
- (void)schedule;
- (void)finishBatch:(NSString *)batchId file:(NSURL *)file status:(NSInteger)status ack:(nullable NSDictionary *)ack;
@end

NS_ASSUME_NONNULL_END
