#import "NavigationCompatibility.h"
#include <assert.h>
#include <math.h>
NSString *TIOProtocolDevice(void){return nil;}
static BOOL Allowed(NSDictionary *b,NSDictionary *d,NSString *device,double now,NSString *contract){return [TIONavigationCompatibility(b,d,device,now,contract)[@"lensNavigationAllowed"] boolValue];}
int main(void){@autoreleasepool{
 NSDictionary *b=@{@"schemaVersion":@1,@"profile":@"daily-navigation",@"expectedFirmwareFamily":@"TLC1",@"candidateZipSha256":@"5e2b85acb9cd25e0b245838e665e39d291eae4aae640308f126718eb3185e519",@"lifelogPolicy":@"pause-restore",@"verifiedControlContractVersion":@"synthetic-control-v1",@"otaToolBuild":@NO};
 NSDictionary *d=@{@"firmwareFamily":@"TLC1",@"candidateZipSha256":b[@"candidateZipSha256"],@"deviceId":@"synthetic-peer",@"checkedAt":@100,@"expiresAt":@200};
 assert(Allowed(b,d,@"synthetic-peer",150,@"synthetic-control-v1"));
 assert(!Allowed(b,d,@"synthetic-peer",150,nil));
 assert(!Allowed(b,d,@"other-peer",150,@"synthetic-control-v1"));
 assert(!Allowed(b,d,nil,150,@"synthetic-control-v1"));
 for(NSNumber *now in @[@99,@200,@201,@(NAN)])assert(!Allowed(b,d,@"synthetic-peer",now.doubleValue,@"synthetic-control-v1"));
 for(NSString *family in @[@"stock",@"unknown",@"TNV1",@"TGR1"]){NSMutableDictionary *bad=[d mutableCopy];bad[@"firmwareFamily"]=family;assert(!Allowed(b,bad,@"synthetic-peer",150,@"synthetic-control-v1"));}
 for(NSString *key in b){NSMutableDictionary *bad=[b mutableCopy];[bad removeObjectForKey:key];assert(!Allowed(bad,d,@"synthetic-peer",150,@"synthetic-control-v1"));}
 for(NSString *key in d){NSMutableDictionary *bad=[d mutableCopy];[bad removeObjectForKey:key];assert(!Allowed(b,bad,@"synthetic-peer",150,@"synthetic-control-v1"));}
 NSMutableDictionary *bad=[b mutableCopy];bad[@"otaToolBuild"]=@YES;assert(!Allowed(bad,d,@"synthetic-peer",150,@"synthetic-control-v1"));
 bad=[d mutableCopy];bad[@"expiresAt"]=@100000;assert(!Allowed(b,bad,@"synthetic-peer",150,@"synthetic-control-v1"));
 assert(![TIONavigationCompatibilityStatus()[@"lensNavigationAllowed"] boolValue]);
 assert(![TIONavigationCompatibility(b,d,@"synthetic-peer",150,@"synthetic-control-v1")[@"deviceFirmwareHashVerified"] boolValue]);
 puts("PASS compatibility: stock, unknown, wrong family/device, expiry, missing manifest, tool and unsupported lifelog contract fail closed");
}return 0;}
