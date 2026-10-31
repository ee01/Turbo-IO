#import <Foundation/Foundation.h>
// Extension policy only. Actions must be executed by a separately verified
// host/device bridge; a successful send is never an observation or an ACK.
@interface TIONavigationLifeLogCoordinator : NSObject
- (instancetype)initWithJournal:(NSDictionary *)journal persist:(BOOL(^)(NSDictionary *journal))persist;
@property(nonatomic,readonly) NSString *state;
@property(nonatomic,readonly) NSDictionary *action;
@property(nonatomic,readonly) NSDictionary *journal;
- (BOOL)beginWithObservation:(NSDictionary *)observation;
- (void)confirmPause:(NSString *)requestID observation:(NSDictionary *)observation;
- (void)navigationStartAccepted:(BOOL)accepted observation:(NSDictionary *)observation;
- (void)endNavigation;
- (void)confirmExit:(BOOL)confirmed observation:(NSDictionary *)observation;
- (void)confirmRestore:(NSString *)requestID observation:(NSDictionary *)observation;
- (void)timeout;
// Recovery requires a fresh observation and an explicit user action. Merely
// constructing this object after a restart never enables recording.
- (void)recoverWithObservation:(NSDictionary *)observation exitConfirmed:(BOOL)exitConfirmed;
@end
