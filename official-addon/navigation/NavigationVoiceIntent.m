#import "NavigationVoiceIntent.h"
#include <math.h>
NSString *TIONavigationVoiceDestination(NSString *text){
    if(![text isKindOfClass:NSString.class]||text.length>128||[text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    text=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(![text hasPrefix:@"导航去"])return nil;
    NSString *place=[[text substringFromIndex:3] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ，。！？,.!?\t"]];
    return place.length&&place.length<=120?place:nil;
}
@implementation TIONavigationVoiceIntent {
    NSTimeInterval(^_clock)(void);
    NSTimeInterval _at;
    NSString *_session,*_source,*_destination;
    NSMutableSet *_seen;
}
- (instancetype)initWithClock:(NSTimeInterval(^)(void))clock{if(!clock)return nil;if((self=[super init])){_clock=[clock copy];_seen=[NSMutableSet new];}return self;}
- (void)cancel{_session=nil;_source=nil;_destination=nil;}
- (BOOL)acceptText:(NSString *)text final:(BOOL)final session:(NSString *)session source:(NSString *)source{
    if(![session isKindOfClass:NSString.class]||!session.length||session.length>200||![source isKindOfClass:NSString.class]||!source.length||source.length>200)return NO;
    // A new utterance invalidates any pending handoff from the previous one.
    if(!final){[self cancel];return NO;}
    NSString *key=[NSString stringWithFormat:@"%lu:%@%@",(unsigned long)source.length,source,session];
    if([_seen containsObject:key])return NO;
    [self cancel];NSString *destination=TIONavigationVoiceDestination(text);if(!destination)return NO;
    // A bounded process cannot silently forget duplicate protection and replay.
    if(_seen.count>=256)return NO;
    NSTimeInterval now=_clock();if(!isfinite(now))return NO;
    [_seen addObject:key];_session=[session copy];_source=[source copy];_destination=destination;_at=now;return YES;
}
- (NSString *)releaseSession:(NSString *)session source:(NSString *)source verifiedIdle:(BOOL)idle{
    if(!_destination)return nil;
    NSTimeInterval age=_clock()-_at;
    if(!isfinite(age)||age<0||age>30){[self cancel];return nil;}
    if(!idle||![_session isEqual:session]||![_source isEqual:source])return nil;
    NSString *destination=_destination;[self cancel];return destination;
}
@end
