#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TIOMemorySyncLifecycle : NSObject
@property(nonatomic, copy, nullable) void (^handler)(void (^completion)(void));
- (BOOL)handleIdentifier:(NSString *)identifier completion:(void (^ _Nullable)(void))completion;
@end

NS_ASSUME_NONNULL_END
