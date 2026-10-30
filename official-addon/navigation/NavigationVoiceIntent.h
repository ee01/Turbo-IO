#import <Foundation/Foundation.h>
NSString *TIONavigationVoiceDestination(NSString *text);
// ASR final / onResponseComplete do not prove the assistant released the page.
// Only a verified workflow-release observer may release this bounded intent.
@interface TIONavigationVoiceIntent : NSObject
- (instancetype)initWithClock:(NSTimeInterval(^)(void))clock;
- (BOOL)acceptText:(NSString *)text final:(BOOL)final session:(NSString *)session source:(NSString *)source;
- (NSString *)releaseSession:(NSString *)session source:(NSString *)source verifiedIdle:(BOOL)idle;
- (void)cancel;
@end
