#import "NavigationLifeLogCoordinator.h"
@implementation TIONavigationLifeLogCoordinator {
    BOOL(^_persist)(NSDictionary *);
    NSString *_source;
    NSNumber *_intentEpoch;
    BOOL _originalEnabled;
}
- (instancetype)initWithJournal:(NSDictionary *)journal persist:(BOOL(^)(NSDictionary *))persist{
    if(!persist)return nil;
    if((self=[super init])){
        _persist=[persist copy];_journal=[journal isKindOfClass:NSDictionary.class]?[journal copy]:@{};
        _state=_journal.count?@"restorePending":@"idle";
        _source=_journal[@"source"];_intentEpoch=_journal[@"userIntentEpoch"];
        _originalEnabled=[_journal[@"originalEnabled"] isEqual:@YES];
    }return self;
}
- (BOOL)valid:(NSDictionary *)o{
    return [o isKindOfClass:NSDictionary.class]&&[o[@"supported"] isEqual:@YES]&&
        [o[@"source"] isKindOfClass:NSString.class]&&[o[@"source"] length]&&
        [o[@"userIntentEpoch"] isKindOfClass:NSNumber.class]&&
        ([o[@"enabled"] isEqual:@YES]||[o[@"enabled"] isEqual:@NO]);
}
- (BOOL)sameSource:(NSDictionary *)o{return [self valid:o]&&[o[@"source"] isEqual:_source];}
- (BOOL)sameIntent:(NSDictionary *)o{return [self sameSource:o]&&[o[@"userIntentEpoch"] isEqual:_intentEpoch];}
- (void)issue:(NSString *)kind enabled:(NSNumber *)enabled{
    NSMutableDictionary *a=[@{@"kind":kind,@"requestID":NSUUID.UUID.UUIDString,@"source":_source} mutableCopy];
    if(enabled)a[@"enabled"]=enabled;_action=a;
}
- (void)pending{_state=@"restorePending";_action=nil;}
- (BOOL)clear{
    if(!_persist(@{})){[self pending];return NO;}
    _journal=@{};_state=@"ended";_action=nil;return YES;
}
- (BOOL)beginWithObservation:(NSDictionary *)o{
    if(![@[@"idle",@"ended"] containsObject:_state]||![self valid:o])return NO;
    _source=[o[@"source"] copy];_intentEpoch=o[@"userIntentEpoch"];_originalEnabled=[o[@"enabled"] boolValue];
    if(_originalEnabled){
        NSDictionary *j=@{@"schemaVersion":@1,@"source":_source,@"userIntentEpoch":_intentEpoch,@"originalEnabled":@YES};
        if(!_persist(j)){_state=@"unavailable";return NO;}
        _journal=j;_state=@"pausing";[self issue:@"pause" enabled:@NO];
    }else{_state=@"starting";[self issue:@"start" enabled:nil];}
    return YES;
}
- (void)confirmPause:(NSString *)rid observation:(NSDictionary *)o{
    if(![_state isEqual:@"pausing"]||![rid isEqual:_action[@"requestID"]])return;
    if(![self sameIntent:o]){[self pending];return;}
    if(![o[@"enabled"] isEqual:@NO])return;
    _state=@"starting";[self issue:@"start" enabled:nil];
}
- (void)restore:(NSDictionary *)o{
    _action=nil;
    if(!_originalEnabled){[self clear];return;}
    if(![self sameSource:o]){[self pending];return;}
    // A same-value manual OFF also changes the user intent epoch. Never undo it.
    if(![o[@"userIntentEpoch"] isEqual:_intentEpoch]||[o[@"enabled"] isEqual:@YES]){[self clear];return;}
    _state=@"restoring";[self issue:@"resume" enabled:@YES];
}
- (void)navigationStartAccepted:(BOOL)accepted observation:(NSDictionary *)o{
    if(![_state isEqual:@"starting"])return;
    if(accepted){_state=@"active";_action=nil;}else [self restore:o];
}
- (void)endNavigation{
    if([_state isEqual:@"active"]){_state=@"stopping";[self issue:@"stop" enabled:nil];}
    else if([@[@"pausing",@"starting"] containsObject:_state])[self pending];
}
- (void)confirmExit:(BOOL)confirmed observation:(NSDictionary *)o{
    if(![_state isEqual:@"stopping"])return;
    if(!confirmed){[self pending];return;}[self restore:o];
}
- (void)confirmRestore:(NSString *)rid observation:(NSDictionary *)o{
    if(![_state isEqual:@"restoring"]||![rid isEqual:_action[@"requestID"]])return;
    if(![self sameIntent:o]){[self pending];return;}
    if([o[@"enabled"] isEqual:@YES])[self clear];
}
- (void)timeout{if(![@[@"idle",@"ended"] containsObject:_state])[self pending];}
- (void)recoverWithObservation:(NSDictionary *)o exitConfirmed:(BOOL)confirmed{
    if(confirmed&&[_state isEqual:@"restorePending"])[self restore:o];
}
@end
