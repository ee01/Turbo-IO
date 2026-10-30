#import "NavigationFreshness.h"
#include <math.h>
static BOOL Number(id n){return [n isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)n)!=CFBooleanGetTypeID()&&isfinite([n doubleValue]);}
NSDictionary *TIONavigationFreshness(NSDictionary *frame,NSUInteger generation,NSTimeInterval now){
    if(![frame isKindOfClass:NSDictionary.class])frame=@{};
    id observed=frame[@"navObservedAt"],location=frame[@"locationObservedAt"],route=frame[@"routeGeneration"];
    BOOL navAgeKnown=Number(observed)&&isfinite(now)&&[observed doubleValue]>=0&&now>=[observed doubleValue];
    double age=navAgeKnown?now-[observed doubleValue]:0;
    BOOL locationAgeKnown=[frame[@"locationEvidenceAvailable"] isEqual:@YES]&&Number(location)&&[location doubleValue]>=0&&isfinite(now)&&now>=[location doubleValue];
    BOOL sameRoute=Number(route)&&generation>0&&[route doubleValue]==generation;
    BOOL fresh=navAgeKnown&&age<=15&&sameRoute&&[frame[@"phase"] isEqual:@"navigating"];
    NSString *reason=!sameRoute?@"route_changed":!navAgeKnown?@"navigation_time_unavailable":age>15?@"navigation_stale":![frame[@"phase"] isEqual:@"navigating"]?@"navigation_inactive":@"navigation_fresh";
    return @{@"navigationInfoFresh":@(fresh),@"freshnessReason":reason,
        @"navigationInfoAgeMs":navAgeKnown?@(age*1000):NSNull.null,
        @"locationAgeMs":locationAgeKnown?@((now-[location doubleValue])*1000):NSNull.null,
        @"locationEvidenceAvailable":@(locationAgeKnown)};
}
