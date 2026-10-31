#import "NavigationLifeLogCoordinator.h"
#include <assert.h>
static NSDictionary *Observation(BOOL enabled,int epoch,NSString *source){return @{@"supported":@YES,@"source":source,@"enabled":@(enabled),@"userIntentEpoch":@(epoch)};}
int main(void){@autoreleasepool{
 __block NSDictionary *disk=@{};
 BOOL(^persist)(NSDictionary *)=^BOOL(NSDictionary *j){disk=j;return YES;};
 NSDictionary *on=Observation(YES,1,@"synthetic-source"),*off=Observation(NO,1,@"synthetic-source");
 for(int cycle=0;cycle<20;cycle++){
  TIONavigationLifeLogCoordinator *c=[[TIONavigationLifeLogCoordinator alloc]initWithJournal:nil persist:persist];
  assert([c beginWithObservation:on]);assert([c.action[@"kind"] isEqual:@"pause"]&&disk.count);
  [c confirmPause:@"old-request" observation:off];assert([c.state isEqual:@"pausing"]);
  [c confirmPause:c.action[@"requestID"] observation:off];assert([c.action[@"kind"] isEqual:@"start"]);
  [c navigationStartAccepted:YES observation:off];assert(!c.action);
  [c endNavigation];assert([c.action[@"kind"] isEqual:@"stop"]);
  [c confirmExit:YES observation:off];assert([c.action[@"kind"] isEqual:@"resume"]);
  [c confirmRestore:c.action[@"requestID"] observation:on];assert([c.state isEqual:@"ended"]&&!disk.count);
  c=[[TIONavigationLifeLogCoordinator alloc]initWithJournal:nil persist:persist];assert([c beginWithObservation:off]);assert([c.action[@"kind"] isEqual:@"start"]&&!disk.count);
  [c navigationStartAccepted:YES observation:off];[c endNavigation];[c confirmExit:YES observation:off];assert([c.state isEqual:@"ended"]&&!c.action);
 }
 TIONavigationLifeLogCoordinator *(^paused)(void)=^{TIONavigationLifeLogCoordinator *c=[[TIONavigationLifeLogCoordinator alloc]initWithJournal:nil persist:persist];assert([c beginWithObservation:on]);[c confirmPause:c.action[@"requestID"] observation:off];return c;};
 TIONavigationLifeLogCoordinator *c=paused();[c navigationStartAccepted:NO observation:off];assert([c.action[@"kind"] isEqual:@"resume"]);
 c=paused();[c navigationStartAccepted:YES observation:off];[c endNavigation];[c confirmExit:NO observation:off];assert([c.state isEqual:@"restorePending"]&&!c.action&&disk.count);
 c=[[TIONavigationLifeLogCoordinator alloc]initWithJournal:disk persist:persist];assert([c.state isEqual:@"restorePending"]&&!c.action);
 [c recoverWithObservation:Observation(NO,1,@"other-source") exitConfirmed:YES];assert(!c.action&&disk.count);
 [c recoverWithObservation:Observation(NO,2,@"synthetic-source") exitConfirmed:YES];assert([c.state isEqual:@"ended"]&&!c.action&&!disk.count);
 c=paused();[c timeout];assert([c.state isEqual:@"restorePending"]&&!c.action&&disk.count);
 c=[[TIONavigationLifeLogCoordinator alloc]initWithJournal:nil persist:^BOOL(NSDictionary *j){(void)j;return NO;}];assert(![c beginWithObservation:on]&&!c.action);
 assert(![c beginWithObservation:@{}]);
 puts("PASS lifelog policy: 20 ON/OFF cycles, correlated pause/restore, START rejection, STOP timeout, restart, same-value user OFF, source isolation and journal failure; synthetic bridge only");
}return 0;}
