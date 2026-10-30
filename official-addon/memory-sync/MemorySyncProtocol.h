#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TIOMemorySyncErrorDomain;
extern NSString *const TIOMemorySyncSessionIdentifier;
extern NSInteger const TIOMemorySyncSchemaVersion;
extern NSUInteger const TIOMemorySyncMaxBatchItems;
extern NSUInteger const TIOMemorySyncMaxBatchBytes;
extern NSUInteger const TIOMemorySyncMaxConcurrentUploads;
extern NSUInteger const TIOMemorySyncMaxAttempts;
extern NSUInteger const TIOMemorySyncMaxRecords;
extern NSUInteger const TIOMemorySyncMaxBytes;

NSString * _Nullable TIOMemorySyncSHA256(NSData *data);
NSString * _Nullable TIOMemorySyncTextHash(NSString *text);
NSData * _Nullable TIOMemorySyncEncodeBatch(NSString *sourceId, NSString *batchId, NSArray<NSDictionary *> *events, NSError **error);
NSArray<NSDictionary *> *TIOMemorySyncNextBatch(NSString *sourceId, NSString *batchId, NSArray<NSDictionary *> *events, NSUInteger maxItems, NSUInteger maxBytes, NSDictionary * _Nullable * _Nullable oversized);
BOOL TIOMemorySyncOriginValid(NSString *origin);
BOOL TIOMemorySyncURLTriggersSync(NSURL *url);
BOOL TIOMemorySyncIsOwnSession(NSString *identifier);
NSDictionary *TIOMemorySyncKeychainAddQuery(NSString *service, NSString *token);

NS_ASSUME_NONNULL_END
