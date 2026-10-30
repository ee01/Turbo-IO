#import "MemorySyncLifecycle.h"
#import "MemorySyncProtocol.h"

@implementation TIOMemorySyncLifecycle
- (BOOL)handleIdentifier:(NSString *)identifier completion:(void (^)(void))completion {
    if (!TIOMemorySyncIsOwnSession(identifier)) return NO;
    if (self.handler) self.handler(completion ?: ^{});
    else if (completion) completion();
    return YES;
}
@end
