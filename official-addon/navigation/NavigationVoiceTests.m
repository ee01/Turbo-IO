#import "NavigationVoiceIntent.h"
#include <assert.h>
int main(void){@autoreleasepool{
 assert([TIONavigationVoiceDestination(@"导航去虹桥火车站。") isEqual:@"虹桥火车站"]);
 for(NSString *s in @[@"导航去",@"不要导航去机场",@"导航去\n机场",@"播放音乐"])assert(!TIONavigationVoiceDestination(s));
 __block double now=1;
 TIONavigationVoiceIntent *v=[[TIONavigationVoiceIntent alloc]initWithClock:^{return now;}];
 assert(![v acceptText:@"导航去机场" final:NO session:@"one" source:@"peer"]);
 assert(![v releaseSession:@"one" source:@"peer" verifiedIdle:YES]);
 assert([v acceptText:@"导航去机场" final:YES session:@"one" source:@"peer"]);
 assert(![v releaseSession:@"one" source:@"peer" verifiedIdle:NO]);
 assert(![v releaseSession:@"old" source:@"peer" verifiedIdle:YES]);
 assert(![v releaseSession:@"one" source:@"other-peer" verifiedIdle:YES]);
 assert([[v releaseSession:@"one" source:@"peer" verifiedIdle:YES] isEqual:@"机场"]);
 assert(![v releaseSession:@"one" source:@"peer" verifiedIdle:YES]);
 assert(![v acceptText:@"导航去机场" final:YES session:@"one" source:@"peer"]);
 assert([v acceptText:@"导航去车站" final:YES session:@"two" source:@"peer"]);now+=31;
 assert(![v releaseSession:@"two" source:@"peer" verifiedIdle:YES]);
 assert([v acceptText:@"导航去车站" final:YES session:@"three" source:@"peer"]);
 [v acceptText:@"另一句话" final:NO session:@"four" source:@"peer"];
 assert(![v releaseSession:@"three" source:@"peer" verifiedIdle:YES]);
 puts("PASS voice intent: exact command, final-only, source/session correlation, idle gate, duplicate suppression, new utterance cancellation and expiry; no host/SDK handoff claimed");
}return 0;}
