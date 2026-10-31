#import "NavigationFreshness.h"
#include <assert.h>
#include <math.h>
int main(void){@autoreleasepool{
 NSDictionary *f=@{@"phase":@"navigating",@"routeGeneration":@7,@"navObservedAt":@100};
 assert([TIONavigationFreshness(f,7,115)[@"navigationInfoFresh"] boolValue]);
 assert(![TIONavigationFreshness(f,7,115.001)[@"navigationInfoFresh"] boolValue]);
 assert(![TIONavigationFreshness(f,8,110)[@"navigationInfoFresh"] boolValue]);
 for(NSNumber *now in @[@99,@(NAN),@(INFINITY)])assert(![TIONavigationFreshness(f,7,now.doubleValue)[@"navigationInfoFresh"] boolValue]);
 assert(TIONavigationFreshness(f,7,110)[@"locationAgeMs"]==NSNull.null);
 assert(![TIONavigationFreshness(f,7,110)[@"locationEvidenceAvailable"] boolValue]);
 for(id observed in @[NSNull.null,@[],@YES,@(-1),@(NAN)]){NSMutableDictionary *b=[f mutableCopy];b[@"navObservedAt"]=observed;assert(![TIONavigationFreshness(b,7,110)[@"navigationInfoFresh"] boolValue]);assert(TIONavigationFreshness(b,7,110)[@"navigationInfoAgeMs"]==NSNull.null);}
 NSMutableDictionary *b=[f mutableCopy];b[@"phase"]=@"weak";assert(![TIONavigationFreshness(b,7,110)[@"navigationInfoFresh"] boolValue]);
 b=[f mutableCopy];b[@"locationObservedAt"]=@105;b[@"locationEvidenceAvailable"]=@YES;assert([TIONavigationFreshness(b,7,110)[@"locationAgeMs"] isEqual:@5000]);
 // Re-rendering or receiving an icon cannot renew the source timestamp.
 for(int i=0;i<20;i++)assert(![TIONavigationFreshness(f,7,116+i)[@"navigationInfoFresh"] boolValue]);
 puts("PASS freshness: source clock, generation, 15s boundary, malformed/future time, weak GPS phase and unavailable location evidence");
}return 0;}
