#import "NativeNavigationUI.h"
#if TIO_DAILY_NAVIGATION
#import "NavigationCompatibility.h"
#import "NavigationFreshness.h"
static NSUInteger RouteGeneration;
static NSTimeInterval NavigationObservedAt;
static BOOL FreshFrame(NSDictionary *frame,NSUInteger generation){
 return [TIONavigationFreshness(frame,generation,NSProcessInfo.processInfo.systemUptime)[@"navigationInfoFresh"] boolValue];
}
#endif
#import "NativeNavigation.h"
#import "TNVTransport.h"
#import "ProtocolContext.h"
#if TIO_OTA_RESEARCH_ENABLED
#import "ExperimentalOTAFlash.h"
#endif
#import <UIKit/UIKit.h>
#import <objc/message.h>
static TNVSession *Session;static TNVTransport *Transport;static NSTimer *Timer;static NSString *Peer;static NSTimeInterval LastSave;
BOOL TNVAlways(void){return [NSUserDefaults.standardUserDefaults boolForKey:@"TurboNavigationAlwaysOnV1"];}
void TNVSetAlways(BOOL value){[NSUserDefaults.standardUserDefaults setBool:value forKey:@"TurboNavigationAlwaysOnV1"];[Session setAlways:value];}
NSDictionary *TNVStatus(void){return Session.status?:@{@"active":@NO,@"busy":@NO,@"snapshots":@0,@"note":@"TNV1专用固件：手机开始导航后可自动打开眼镜页面"};}
BOOL TNVConsume(NSDictionary *e){if(Peer&&![Peer isEqual:TIOProtocolDevice()])[Session disconnect];return [Session consume:e];}
BOOL TNVPauseForOTA(void){return !Session.active&&!Session.busy;}
void TNVPump(void){
 if(Peer&&![Peer isEqual:TIOProtocolDevice()])[Session disconnect];
#if TIO_DAILY_NAVIGATION
 if(Session.active&&(![TIONavigationCompatibilityStatus()[@"lensNavigationAllowed"] boolValue]||NSProcessInfo.processInfo.systemUptime-NavigationObservedAt>15))[Session stop];
#endif
 [Session pump];NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(now-LastSave<1)return;LastSave=now;
 NSString *root=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon"];
 [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 NSMutableDictionary *d=[TNVStatus() mutableCopy];d[@"build"]=@"TNV1-SOURCE-01-BG";d[@"physicalVerified"]=@NO;d[@"timestamp"]=@(NSDate.date.timeIntervalSince1970);d[@"appState"]=@(UIApplication.sharedApplication.applicationState);
 NSString *file=[root stringByAppendingPathComponent:@"native-navigation-status.json"];[[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingSortedKeys error:nil] writeToFile:file options:NSDataWritingAtomic error:nil];[NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:file error:nil];
}
BOOL TNVStart(NSDictionary *frame){
 NSCAssert(NSThread.isMainThread,@"main only");
#if TIO_DAILY_NAVIGATION
 id generation=frame[@"routeGeneration"];
 if(![TIONavigationCompatibilityStatus()[@"lensNavigationAllowed"] boolValue]||![generation isKindOfClass:NSNumber.class]||!FreshFrame(frame,[generation unsignedIntegerValue]))return NO;
 RouteGeneration=[frame[@"routeGeneration"] unsignedIntegerValue];NavigationObservedAt=[frame[@"navObservedAt"] doubleValue];
#endif
 if(Session.active||Session.busy
#if TIO_OTA_RESEARCH_ENABLED
 ||[TIOOTAFlashStatus()[@"stage"] unsignedIntegerValue]
#endif
 )return NO;
 NSString *device=TIOProtocolDevice();if(!device.length)return NO;TNScene scene;if(!TNVScene(frame,TNVAlways(),&scene))return NO;
 NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;uint64_t last=[[defaults objectForKey:@"TurboNavigationSessionCounterV1"] unsignedLongLongValue];
 uint64_t epoch=(uint64_t)MAX(1,NSDate.date.timeIntervalSince1970);uint64_t sid=MAX(last+1,epoch);if(sid>UINT32_MAX)return NO;
 [defaults setObject:@(sid) forKey:@"TurboNavigationSessionCounterV1"];if(![defaults synchronize])return NO;
 Peer=[device copy];NSString *pinned=Peer;
 NSURL *root=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/NativeNavigationV1"] isDirectory:YES];
 Transport=[[TNVTransport alloc]initWithRoot:root device:device currentDevice:^{return TIOProtocolDevice();} call:^BOOL(NSString *method,NSDictionary *args,void(^result)(id)){
  if(!NSThread.isMainThread||![pinned isEqual:TIOProtocolDevice()])return NO;id plugin=TIOProtocolPlugin();Class cls=NSClassFromString(@"FlutterMethodCall");SEL make=NSSelectorFromString(@"methodCallWithMethodName:arguments:"),handle=NSSelectorFromString(@"handleMethodCall:result:");
  if(!plugin||![cls respondsToSelector:make]||![plugin respondsToSelector:handle])return NO;
  @try{id call=((id(*)(id,SEL,id,id))objc_msgSend)(cls,make,method,args);((void(*)(id,SEL,id,id))objc_msgSend)(plugin,handle,call,[result copy]);return YES;}@catch(NSException *e){return NO;}
 }];TNVTransport *transport=Transport;
 Session=[[TNVSession alloc]initWithDevice:device session:(uint32_t)sid clock:^{return NSProcessInfo.processInfo.systemUptime;} sender:^(NSData *packet,NSString *task,TNVSubmitted done){[transport send:packet task:task submitted:done];} cleanup:^(NSString *task){[transport cleanup:task];}];
 if(!Timer)Timer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t){TNVPump();}];return [Session start:frame always:TNVAlways()];
}
void TNVOffer(NSDictionary *frame){
#if TIO_DAILY_NAVIGATION
 if(!FreshFrame(frame,RouteGeneration)){[Session stop];return;}
 NavigationObservedAt=[frame[@"navObservedAt"] doubleValue];
#endif
 [Session offer:frame];
}
void TNVStop(void){[Session stop];}
