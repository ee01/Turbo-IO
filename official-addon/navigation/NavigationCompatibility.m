#import "NavigationCompatibility.h"
#import "ProtocolContext.h"
#include <math.h>
static NSString *const Candidate=@"5e2b85acb9cd25e0b245838e665e39d291eae4aae640308f126718eb3185e519";
NSDictionary *TIONavigationCompatibility(NSDictionary *build,NSDictionary *deployment,NSString *device,NSTimeInterval now,NSString *contract){
    if(![build isKindOfClass:NSDictionary.class])build=@{};
    if(![deployment isKindOfClass:NSDictionary.class])deployment=@{};
    NSString *reason=@"镜片导航尚未核对；手机导航可独立使用";
    BOOL validBuild=[build isKindOfClass:NSDictionary.class]&&[build[@"schemaVersion"] isEqual:@1]&&
        [build[@"profile"] isEqual:@"daily-navigation"]&&[build[@"expectedFirmwareFamily"] isEqual:@"TLC1"]&&
        [build[@"candidateZipSha256"] isEqual:Candidate]&&[build[@"lifelogPolicy"] isEqual:@"pause-restore"]&&[build[@"otaToolBuild"] isEqual:@NO];
    BOOL allowed=NO;
    if(!validBuild)reason=@"缺少匹配的导航构建清单；手机导航可独立使用";
    else if([deployment[@"firmwareFamily"] isEqual:@"stock"])reason=@"原厂固件仅使用手机导航，镜片导航不可用";
    else if([build[@"otaToolBuild"] isEqual:@YES])reason=@"升级工具不能启动导航";
    else if(!contract.length||![build[@"verifiedControlContractVersion"] isEqual:contract])reason=@"智记暂停与恢复接口尚未验证，镜片导航暂不可用";
    else {
        id checked=deployment[@"checkedAt"],expires=deployment[@"expiresAt"];
        BOOL dates=[checked isKindOfClass:NSNumber.class]&&[expires isKindOfClass:NSNumber.class]&&
            isfinite(now)&&isfinite([checked doubleValue])&&isfinite([expires doubleValue])&&
            [checked doubleValue]<=now&&[expires doubleValue]>now&&[expires doubleValue]-[checked doubleValue]<=86400;
        allowed=device.length&&[deployment[@"deviceId"] isEqual:device]&&dates&&
            [deployment[@"firmwareFamily"] isEqual:@"TLC1"]&&[deployment[@"candidateZipSha256"] isEqual:Candidate];
        if(allowed)reason=@"部署记录已核对；等待本次导航与眼镜回执";
    }
    return @{@"lensNavigationAllowed":@(allowed),@"otaToolBuild":@([build[@"otaToolBuild"] isEqual:@YES]),
        @"firmwareEvidence":allowed?@"manual-deployment-record":@"unverified",@"deviceFirmwareHashVerified":@NO,@"reason":reason};
}
NSDictionary *TIONavigationCompatibilityStatus(void){
    NSString *file=[NSBundle.mainBundle pathForResource:@"TurboIONavigationBuild" ofType:@"json"];
    NSData *data=file?[NSData dataWithContentsOfFile:file]:nil;
    id build=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![build isKindOfClass:NSDictionary.class])build=@{};
    id deployment=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TurboIONavigationDeploymentV1"]?:@{};
    // No verified 1.0.5 switch/ack/user-intent bridge exists yet. An edited
    // manifest or defaults cannot manufacture that capability.
    return TIONavigationCompatibility(build,deployment,TIOProtocolDevice(),NSDate.date.timeIntervalSince1970,nil);
}
