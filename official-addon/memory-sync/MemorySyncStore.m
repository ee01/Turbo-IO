#import "MemorySyncStore.h"
#import <sqlite3.h>

static NSString *const Schema =
@"CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
"CREATE TABLE IF NOT EXISTS revisions ("
" source_id TEXT NOT NULL, event_id TEXT NOT NULL, revision INTEGER NOT NULL,"
" session_id TEXT NOT NULL, received_at TEXT NOT NULL, updated_at TEXT NOT NULL,"
" role TEXT NOT NULL, text TEXT NOT NULL, text_hash TEXT NOT NULL, accept_seq INTEGER NOT NULL,"
" text_bytes INTEGER NOT NULL, PRIMARY KEY (source_id, event_id, revision));"
"CREATE TABLE IF NOT EXISTS records ("
" source_id TEXT NOT NULL, event_id TEXT NOT NULL, revision INTEGER NOT NULL,"
" session_id TEXT NOT NULL, received_at TEXT NOT NULL, updated_at TEXT NOT NULL,"
" role TEXT NOT NULL, text TEXT NOT NULL, text_hash TEXT NOT NULL, accept_seq INTEGER NOT NULL,"
" text_bytes INTEGER NOT NULL, PRIMARY KEY (source_id, event_id));"
"CREATE TABLE IF NOT EXISTS outbox ("
" source_id TEXT NOT NULL, event_id TEXT NOT NULL, revision INTEGER NOT NULL,"
" target_id TEXT NOT NULL, state TEXT NOT NULL, batch_id TEXT,"
" attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT, last_error TEXT,"
" created_at TEXT NOT NULL, PRIMARY KEY (source_id, event_id, revision));"
"CREATE TABLE IF NOT EXISTS batches ("
" batch_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, target_id TEXT NOT NULL,"
" payload_hash TEXT, state TEXT NOT NULL, file_path TEXT, task_identifier TEXT,"
" attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at TEXT, last_error TEXT,"
" created_at TEXT NOT NULL, ack_at TEXT);"
"CREATE TABLE IF NOT EXISTS batch_items ("
" batch_id TEXT NOT NULL, source_id TEXT NOT NULL, event_id TEXT NOT NULL, revision INTEGER NOT NULL,"
" PRIMARY KEY (batch_id, source_id, event_id, revision));"
"CREATE TABLE IF NOT EXISTS migration ("
" id INTEGER PRIMARY KEY, source_path TEXT NOT NULL, source_hash TEXT NOT NULL UNIQUE,"
" imported_count INTEGER NOT NULL, imported_at TEXT NOT NULL);";

@implementation TIOMemorySyncStore {
    sqlite3 *_db;
    NSURL *_directory;
    NSLock *_lock;
}

- (instancetype)initWithDirectory:(NSURL *)directory error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _directory = directory;
    _lock = [NSLock new];
    NSError *local = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&local]) {
        if (error) *error = local;
        return nil;
    }
    NSURL *database = [directory URLByAppendingPathComponent:@"memory-sync.sqlite"];
    if (sqlite3_open_v2(database.path.fileSystemRepresentation, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (error) *error = [self failure:@"无法打开本机记忆库"];
        return nil;
    }
    sqlite3_busy_timeout(_db, 3000);
    if (![self exec:@"PRAGMA journal_mode=WAL"] || ![self exec:@"PRAGMA synchronous=FULL"] || ![self exec:@"PRAGMA foreign_keys=ON"] || ![self exec:Schema]) {
        if (error) *error = [self failure:@"无法初始化本机记忆库"];
        return nil;
    }
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:database.path error:nil];
    [_lock lock];
    [self ensureDefaults];
    [self migrateLegacy];
    if ([self flag:@"capture_enabled"]) [self put:@"session_id" value:NSUUID.UUID.UUIDString];
    [_lock unlock];
    return self;
}

- (void)dealloc {
    if (_db) sqlite3_close(_db);
}

- (nullable NSDictionary *)recordText:(NSString *)text round:(NSString *)round role:(NSString *)role at:(NSDate *)date generation:(uint64_t)generation applyUploadPolicy:(BOOL)policy error:(NSError **)error {
    if (!text.length || text.length > 32000 || round.length > 512 || role.length > 80) {
        if (error) *error = [self failure:@"文字、轮次或角色超出可保存范围"];
        return nil;
    }
    if (!role.length) {
        if (error) *error = [self failure:@"缺少角色"];
        return nil;
    }
    [_lock lock];
    if (![self exec:@"BEGIN IMMEDIATE"]) {
        [_lock unlock];
        if (error) *error = [self failure:@"本机记忆库正忙"];
        return nil;
    }
    NSDictionary *result = [self recordLocked:text round:round ?: @"" role:role at:date ?: NSDate.date generation:generation policy:policy error:error];
    [self exec:result ? @"COMMIT" : @"ROLLBACK"];
    [_lock unlock];
    return result;
}

- (BOOL)setCaptureEnabled:(BOOL)enabled error:(NSError **)error {
    [_lock lock];
    if (enabled) {
        [self put:@"capture_enabled" value:@"1"];
        [self put:@"session_id" value:NSUUID.UUID.UUIDString];
    } else {
        unsigned long long generation = [self number:@"generation"] + 1;
        [self put:@"generation" value:[NSString stringWithFormat:@"%llu", generation]];
        [self put:@"capture_enabled" value:@"0"];
    }
    [_lock unlock];
    return YES;
}

- (BOOL)grantUploadConsent:(NSError **)error {
    [_lock lock];
    if (![self flag:@"upload_consent"]) {
        unsigned long long start = [self number:@"last_accept_seq"] + 1;
        [self put:@"upload_start_sequence" value:[NSString stringWithFormat:@"%llu", start]];
        [self put:@"upload_consent" value:@"1"];
    }
    [_lock unlock];
    return YES;
}

- (BOOL)setUploadPaused:(BOOL)paused error:(NSError **)error {
    [_lock lock];
    [self put:@"upload_paused" value:paused ? @"1" : @"0"];
    [_lock unlock];
    return YES;
}

- (BOOL)pairOrigin:(NSString *)origin error:(NSError **)error {
    if (!TIOMemorySyncOriginValid(origin)) {
        if (error) *error = [self failure:@"需要不带账号、查询参数的 https 源站"];
        return NO;
    }
    [_lock lock];
    [self put:@"paired_origin" value:origin];
    [self put:@"paired_target_id" value:origin];
    [self put:@"source_bound" value:@"1"];
    [self put:@"auth_paused" value:@"0"];
    sqlite3_stmt *stmt = [self prepare:@"UPDATE outbox SET state='pending', last_error=NULL, next_attempt_at=NULL WHERE state='auth_paused' AND target_id=?"];
    sqlite3_bind_text(stmt, 1, origin.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    [_lock unlock];
    return YES;
}

- (BOOL)setCompatibilityPaused:(BOOL)paused error:(NSError **)error {
    [_lock lock];
    [self put:@"compatibility_paused" value:paused ? @"1" : @"0"];
    [_lock unlock];
    return YES;
}

- (BOOL)setSourcePaused:(BOOL)paused error:(NSError **)error {
    [_lock lock];
    [self put:@"source_paused" value:paused ? @"1" : @"0"];
    [_lock unlock];
    return YES;
}

- (BOOL)authorizeHistoricalUpload:(NSError **)error {
    [_lock lock];
    NSString *target = [self get:@"paired_target_id"];
    if (!target.length || ![self flag:@"source_bound"]) {
        [_lock unlock];
        if (error) *error = [self failure:@"先完成配对，再决定是否上传已有副本"];
        return NO;
    }
    sqlite3_stmt *stmt = [self prepare:
        @"INSERT INTO outbox(source_id,event_id,revision,target_id,state,attempt_count,created_at) "
        "SELECT source_id,event_id,revision,?, 'pending', 0, ? FROM records r "
        "WHERE NOT EXISTS (SELECT 1 FROM outbox o WHERE o.source_id=r.source_id AND o.event_id=r.event_id AND o.revision=r.revision)"];
    NSString *now = [self iso:NSDate.date];
    sqlite3_bind_text(stmt, 1, target.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, now.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    [_lock unlock];
    if (!ok && error) *error = [self failure:@"未能把已有副本加入上传队列"];
    return ok;
}

- (uint64_t)generation { [_lock lock]; uint64_t value = [self number:@"generation"]; [_lock unlock]; return value; }
- (BOOL)captureEnabled { [_lock lock]; BOOL value = [self flag:@"capture_enabled"]; [_lock unlock]; return value; }
- (NSString *)sessionId { [_lock lock]; NSString *value = [self get:@"session_id"] ?: @""; [_lock unlock]; return value; }
- (NSString *)sourceId { [_lock lock]; NSString *value = [self get:@"source_id"] ?: @""; [_lock unlock]; return value; }

- (NSArray<NSDictionary *> *)snapshot:(NSError **)error {
    [_lock lock];
    sqlite3_stmt *stmt = [self prepare:@"SELECT event_id,revision,session_id,role,text,received_at,updated_at FROM records ORDER BY received_at,event_id"];
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [rows addObject:@{
            @"id": [self column:stmt index:0],
            @"revision": @([self columnInt:stmt index:1]),
            @"sessionId": [self column:stmt index:2],
            @"role": [self column:stmt index:3],
            @"text": [self column:stmt index:4],
            @"at": [self column:stmt index:5],
            @"updatedAt": [self column:stmt index:6]
        }];
    }
    sqlite3_finalize(stmt);
    [_lock unlock];
    return rows;
}

- (NSDictionary *)status {
    [_lock lock];
    BOOL capture = [self flag:@"capture_enabled"];
    BOOL consent = [self flag:@"upload_consent"];
    BOOL paused = [self flag:@"upload_paused"];
    BOOL paired = [self flag:@"source_bound"] && [self get:@"paired_target_id"].length > 0;
    BOOL compatibility = [self flag:@"compatibility_paused"];
    BOOL sourcePaused = [self flag:@"source_paused"];
    BOOL auth = [self flag:@"auth_paused"];
    BOOL migration = [self flag:@"migration_blocked"];
    NSString *phase = @"off";
    if (migration) phase = @"migration_blocked";
    else if (compatibility) phase = @"compatibility_paused";
    else if (sourcePaused) phase = @"source_paused";
    else if (!capture) phase = @"off";
    else if (!consent) phase = @"local_only";
    else if (!paired) phase = @"unpaired";
    else if (auth) phase = @"auth_paused";
    else if (paused) phase = @"upload_paused";
    else phase = @"ready";
    NSDictionary *status = @{
        @"captureEnabled": @(capture),
        @"uploadConsented": @(consent),
        @"uploadPaused": @(paused),
        @"paired": @(paired),
        @"compatibilityPaused": @(compatibility),
        @"sourcePaused": @(sourcePaused),
        @"authPaused": @(auth),
        @"migrationBlocked": @(migration),
        @"phase": phase,
        @"running": @(capture && !compatibility && !sourcePaused && !migration),
        @"pendingCount": @([self countSql:@"SELECT COUNT(*) FROM outbox WHERE state IN ('pending','retry_wait','prepared','submitted') AND target_id=?" text:[self get:@"paired_target_id"] ?: @""]),
        @"oldestPendingAt": [self textSql:@"SELECT MIN(created_at) FROM outbox WHERE state IN ('pending','retry_wait','prepared','submitted')"] ?: @"",
        @"heldForOtherTarget": @([self countSql:@"SELECT COUNT(*) FROM outbox WHERE state NOT IN ('acknowledged','error') AND target_id!=?" text:[self get:@"paired_target_id"] ?: @""]),
        @"recordCount": @([self countSql:@"SELECT COUNT(*) FROM records" text:nil]),
        @"textBytes": @([self countSql:@"SELECT COALESCE(SUM(text_bytes),0) FROM records" text:nil]),
        @"lastError": [self textSql:@"SELECT last_error FROM batches WHERE last_error IS NOT NULL AND state!='acknowledged' ORDER BY created_at DESC LIMIT 1"] ?: @"",
        @"lastAckAt": [self textSql:@"SELECT MAX(ack_at) FROM batches"] ?: @"",
        @"rejectedStale": @([self number:@"rejected_stale"]),
        @"sourceId": [self get:@"source_id"] ?: @"",
        @"origin": [self get:@"paired_origin"] ?: @"",
        @"sessionId": [self get:@"session_id"] ?: @""
    };
    [_lock unlock];
    return status;
}

- (BOOL)recover:(NSError **)error {
    [_lock lock];
    sqlite3_stmt *stmt = [self prepare:@"SELECT batch_id,file_path,state,task_identifier,attempt_count FROM batches WHERE state IN ('prepared','submitted','retry_wait')"];
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [rows addObject:@{
            @"batchId": [self column:stmt index:0],
            @"path": [self column:stmt index:1],
            @"state": [self column:stmt index:2],
            @"task": [self column:stmt index:3],
            @"attempts": @([self columnInt:stmt index:4])
        }];
    }
    sqlite3_finalize(stmt);
    for (NSDictionary *row in rows) {
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:row[@"path"]];
        if (!exists) {
            NSString *fallback = [[_directory URLByAppendingPathComponent:@"outgoing"] URLByAppendingPathComponent:[row[@"batchId"] stringByAppendingPathExtension:@"jsonl"]].path;
            exists = [NSFileManager.defaultManager fileExistsAtPath:fallback];
        }
        BOOL submitted = [row[@"state"] isEqual:@"submitted"] || [row[@"task"] length] > 0;
        if (exists) continue;
        if (!submitted && [row[@"attempts"] integerValue] == 0) {
            [self resetBatch:row[@"batchId"]];
        } else {
            [self failLocked:row[@"batchId"] code:@"batch_file_missing" retry:nil auth:NO];
        }
    }
    NSURL *outgoing = [_directory URLByAppendingPathComponent:@"outgoing" isDirectory:YES];
    for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:outgoing includingPropertiesForKeys:nil options:0 error:nil] ?: @[]) {
        NSString *batchId = file.lastPathComponent.stringByDeletingPathExtension;
        if (!batchId.length || [batchId hasPrefix:@"."]) continue;
        if ([self countSql:@"SELECT COUNT(*) FROM batches WHERE batch_id=?" text:batchId] == 0) {
            [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        }
    }
    [_lock unlock];
    return YES;
}

- (NSArray<NSDictionary *> *)uploadCandidatesAt:(NSDate *)now limit:(NSUInteger)limit {
    [_lock lock];
    if (![self uploadsAllowed]) { [_lock unlock]; return @[]; }
    sqlite3_stmt *stmt = [self prepare:
        @"SELECT r.source_id,r.event_id,r.revision,r.session_id,r.received_at,r.updated_at,r.role,r.text,r.text_hash "
        "FROM outbox o JOIN revisions r ON r.source_id=o.source_id AND r.event_id=o.event_id AND r.revision=o.revision "
        "WHERE o.state IN ('pending','retry_wait') AND o.batch_id IS NULL AND o.target_id=? AND o.attempt_count<? "
        "AND (o.next_attempt_at IS NULL OR o.next_attempt_at<=?) ORDER BY o.created_at LIMIT ?"];
    NSString *target = [self get:@"paired_target_id"] ?: @"";
    NSString *stamp = [self iso:now ?: NSDate.date];
    sqlite3_bind_text(stmt, 1, target.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, TIOMemorySyncMaxAttempts);
    sqlite3_bind_text(stmt, 3, stamp.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, (sqlite3_int64)MAX(limit, 1));
    NSMutableArray *items = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        NSDictionary *event = @{
            @"schemaVersion": @(TIOMemorySyncSchemaVersion),
            @"sourceId": [self column:stmt index:0],
            @"eventId": [self column:stmt index:1],
            @"revision": @([self columnInt:stmt index:2]),
            @"sessionId": [self column:stmt index:3],
            @"receivedAt": [self column:stmt index:4],
            @"updatedAt": [self column:stmt index:5],
            @"role": [self column:stmt index:6],
            @"text": [self column:stmt index:7],
            @"textHash": [self column:stmt index:8]
        };
        [items addObject:@{@"event": event, @"eventId": event[@"eventId"], @"revision": event[@"revision"]}];
    }
    sqlite3_finalize(stmt);
    [_lock unlock];
    return items;
}

- (NSArray<NSDictionary *> *)resumableBatchesAt:(NSDate *)now {
    [_lock lock];
    if (![self uploadsAllowed]) { [_lock unlock]; return @[]; }
    sqlite3_stmt *stmt = [self prepare:@"SELECT batch_id,source_id,payload_hash,file_path,state FROM batches WHERE state='submitted' OR (state IN ('prepared','retry_wait') AND (next_attempt_at IS NULL OR next_attempt_at<=?)) ORDER BY created_at"];
    sqlite3_bind_text(stmt, 1, [self iso:now ?: NSDate.date].UTF8String, -1, SQLITE_TRANSIENT);
    NSMutableArray *rows = [NSMutableArray array];
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [rows addObject:@{
            @"batchId": [self column:stmt index:0],
            @"sourceId": [self column:stmt index:1],
            @"payloadHash": [self column:stmt index:2],
            @"filePath": [self column:stmt index:3],
            @"state": [self column:stmt index:4]
        }];
    }
    sqlite3_finalize(stmt);
    [_lock unlock];
    return rows;
}

- (BOOL)beginBatch:(NSString *)batchId items:(NSArray<NSDictionary *> *)items fileURL:(NSURL *)file hash:(NSString *)hash error:(NSError **)error {
    if (!batchId.length || !items.count || !file.path.length || hash.length != 64) {
        if (error) *error = [self failure:@"批次文件尚未准备好"];
        return NO;
    }
    [_lock lock];
    if (![self exec:@"BEGIN IMMEDIATE"]) { [_lock unlock]; return NO; }
    NSString *target = [self get:@"paired_target_id"] ?: @"";
    NSString *source = [self get:@"source_id"] ?: @"";
    BOOL ok = YES;
    for (NSDictionary *item in items) {
        sqlite3_stmt *stmt = [self prepare:@"SELECT state,target_id FROM outbox WHERE source_id=? AND event_id=? AND revision=?"];
        sqlite3_bind_text(stmt, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [item[@"eventId"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 3, [item[@"revision"] longLongValue]);
        BOOL eligible = sqlite3_step(stmt) == SQLITE_ROW;
        NSString *state = eligible ? [self column:stmt index:0] : @"";
        NSString *itemTarget = eligible ? [self column:stmt index:1] : @"";
        sqlite3_finalize(stmt);
        if (!eligible || ![itemTarget isEqual:target] || !([state isEqual:@"pending"] || [state isEqual:@"retry_wait"])) ok = NO;
    }
    if (ok) {
        sqlite3_stmt *batch = [self prepare:@"INSERT INTO batches(batch_id,source_id,target_id,payload_hash,state,file_path,attempt_count,created_at) VALUES(?,?,?,?, 'prepared', ?,0,?)"];
        NSString *now = [self iso:NSDate.date];
        sqlite3_bind_text(batch, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(batch, 2, source.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(batch, 3, target.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(batch, 4, hash.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(batch, 5, file.path.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(batch, 6, now.UTF8String, -1, SQLITE_TRANSIENT);
        ok = sqlite3_step(batch) == SQLITE_DONE;
        sqlite3_finalize(batch);
    }
    if (ok) {
        for (NSDictionary *item in items) {
            sqlite3_stmt *link = [self prepare:@"INSERT INTO batch_items(batch_id,source_id,event_id,revision) VALUES(?,?,?,?)"];
            sqlite3_bind_text(link, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(link, 2, source.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(link, 3, [item[@"eventId"] UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(link, 4, [item[@"revision"] longLongValue]);
            ok = sqlite3_step(link) == SQLITE_DONE;
            sqlite3_finalize(link);
            if (!ok) break;
            sqlite3_stmt *mark = [self prepare:@"UPDATE outbox SET state='prepared', batch_id=? WHERE source_id=? AND event_id=? AND revision=?"];
            sqlite3_bind_text(mark, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(mark, 2, source.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(mark, 3, [item[@"eventId"] UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(mark, 4, [item[@"revision"] longLongValue]);
            ok = sqlite3_step(mark) == SQLITE_DONE;
            sqlite3_finalize(mark);
            if (!ok) break;
        }
    }
    [self exec:ok ? @"COMMIT" : @"ROLLBACK"];
    [_lock unlock];
    if (!ok && error) *error = [self failure:@"待传项已变化，这批没有提交"];
    return ok;
}

- (BOOL)markSubmittedBatch:(NSString *)batchId taskIdentifier:(NSString *)task error:(NSError **)error {
    [_lock lock];
    sqlite3_stmt *stmt = [self prepare:@"UPDATE batches SET state='submitted', task_identifier=COALESCE(?, task_identifier) WHERE batch_id=? AND state IN ('prepared','submitted','retry_wait')"];
    sqlite3_bind_text(stmt, 1, task.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL ok = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(_db) == 1;
    sqlite3_finalize(stmt);
    if (ok) {
        sqlite3_stmt *items = [self prepare:@"UPDATE outbox SET state='submitted' WHERE batch_id=? AND state IN ('prepared','retry_wait')"];
        sqlite3_bind_text(items, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(items);
        sqlite3_finalize(items);
    }
    [_lock unlock];
    return ok;
}

- (BOOL)acknowledgeBatch:(NSString *)batchId ack:(NSDictionary *)ack error:(NSError **)error {
    [_lock lock];
    sqlite3_stmt *batch = [self prepare:@"SELECT source_id,payload_hash,state FROM batches WHERE batch_id=?"];
    sqlite3_bind_text(batch, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL found = sqlite3_step(batch) == SQLITE_ROW;
    NSString *source = found ? [self column:batch index:0] : @"";
    NSString *hash = found ? [self column:batch index:1] : @"";
    NSString *state = found ? [self column:batch index:2] : @"";
    sqlite3_finalize(batch);
    NSArray *events = [ack[@"events"] isKindOfClass:NSArray.class] ? ack[@"events"] : @[];
    BOOL matches = found && [state isEqual:@"submitted"] && [ack[@"sourceId"] isEqual:source] && [ack[@"batchId"] isEqual:batchId] && [ack[@"payloadHash"] isEqual:hash] && [ack[@"committedAt"] isKindOfClass:NSString.class];
    if (matches) {
        sqlite3_stmt *items = [self prepare:@"SELECT event_id,revision FROM batch_items WHERE batch_id=?"];
        sqlite3_bind_text(items, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(items) == SQLITE_ROW && matches) {
            NSString *eventId = [self column:items index:0];
            long long revision = [self columnInt:items index:1];
            BOOL listed = NO;
            for (NSDictionary *event in events) {
                if ([event[@"eventId"] isEqual:eventId] && [event[@"revision"] longLongValue] == revision) listed = YES;
            }
            matches = listed;
        }
        sqlite3_finalize(items);
    }
    if (!matches) {
        [_lock unlock];
        if (error) *error = [self failure:@"回执与这批文件不一致，队列保持不动"];
        return NO;
    }
    sqlite3_stmt *done = [self prepare:@"UPDATE batches SET state='acknowledged', ack_at=?, last_error=NULL WHERE batch_id=?"];
    sqlite3_bind_text(done, 1, [ack[@"committedAt"] UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(done, 2, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(done);
    sqlite3_finalize(done);
    sqlite3_stmt *outbox = [self prepare:@"UPDATE outbox SET state='acknowledged', last_error=NULL WHERE batch_id=?"];
    sqlite3_bind_text(outbox, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(outbox);
    sqlite3_finalize(outbox);
    [_lock unlock];
    return YES;
}

- (BOOL)failBatch:(NSString *)batchId code:(NSString *)code retryAt:(NSDate *)retryAt authPause:(BOOL)authPause error:(NSError **)error {
    [_lock lock];
    [self failLocked:batchId code:code retry:retryAt auth:authPause];
    [_lock unlock];
    return YES;
}

- (BOOL)markEventError:(NSString *)eventId revision:(uint64_t)revision code:(NSString *)code error:(NSError **)error {
    [_lock lock];
    sqlite3_stmt *stmt = [self prepare:@"UPDATE outbox SET state='error', last_error=? WHERE event_id=? AND revision=? AND source_id=?"];
    sqlite3_bind_text(stmt, 1, code.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, eventId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 3, (sqlite3_int64)revision);
    sqlite3_bind_text(stmt, 4, ([self get:@"source_id"] ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    [_lock unlock];
    return YES;
}

- (void)reconcileTasks:(NSDictionary<NSString *, NSString *> *)batchToTask {
    [_lock lock];
    [batchToTask enumerateKeysAndObjectsUsingBlock:^(NSString *batchId, NSString *task, BOOL *stop) {
        sqlite3_stmt *stmt = [self prepare:@"UPDATE batches SET state='submitted', task_identifier=? WHERE batch_id=? AND state='prepared' AND (task_identifier IS NULL OR task_identifier='')" ];
        sqlite3_bind_text(stmt, 1, task.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, batchId.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }];
    [_lock unlock];
}

- (NSDictionary *)recordLocked:(NSString *)text round:(NSString *)round role:(NSString *)role at:(NSDate *)date generation:(uint64_t)generation policy:(BOOL)policy error:(NSError **)error {
    if (policy) {
        if ([self flag:@"migration_blocked"]) return [self rejected:@"migration"];
        if ([self flag:@"compatibility_paused"] || [self flag:@"source_paused"]) return [self rejected:@"paused"];
        if (generation != [self number:@"generation"]) {
            [self put:@"rejected_stale" value:[NSString stringWithFormat:@"%llu", [self number:@"rejected_stale"] + 1]];
            return [self rejected:@"generation"];
        }
        if (![self flag:@"capture_enabled"]) return [self rejected:@"capture"];
    }
    NSString *source = [self get:@"source_id"] ?: @"";
    NSString *session = policy ? ([self get:@"session_id"] ?: @"") : @"legacy";
    if (policy && !session.length) return [self rejected:@"session"];
    NSString *eventId = [self eventIdForRound:round role:role session:session policy:policy];
    if (!eventId) {
        if (error) *error = [self failure:@"无法为这条文字生成稳定身份"];
        return nil;
    }
    NSString *digest = TIOMemorySyncTextHash(text);
    NSUInteger bytes = [text dataUsingEncoding:NSUTF8StringEncoding].length;
    sqlite3_stmt *current = [self prepare:@"SELECT revision,text_hash,text_bytes FROM records WHERE source_id=? AND event_id=?"];
    sqlite3_bind_text(current, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(current, 2, eventId.UTF8String, -1, SQLITE_TRANSIENT);
    BOOL exists = sqlite3_step(current) == SQLITE_ROW;
    long long revision = exists ? [self columnInt:current index:0] : 0;
    NSString *currentHash = exists ? [self column:current index:1] : @"";
    long long currentBytes = exists ? [self columnInt:current index:2] : 0;
    sqlite3_finalize(current);
    if (exists && [currentHash isEqual:digest]) {
        return @{@"accepted": @YES, @"duplicate": @YES, @"eventId": eventId, @"revision": @(revision)};
    }
    long long nextRevision = exists ? revision + 1 : 1;
    long long total = [self countSql:@"SELECT COALESCE(SUM(text_bytes),0) FROM records" text:nil] - (exists ? currentBytes : 0) + (long long)bytes;
    long long count = [self countSql:@"SELECT COUNT(*) FROM records" text:nil] + (exists ? 0 : 1);
    if (count > (long long)TIOMemorySyncMaxRecords || total > (long long)TIOMemorySyncMaxBytes) {
        if (error) *error = [self failure:@"本机归档已满，未丢弃未确认的文字"];
        return nil;
    }
    unsigned long long acceptSeq = [self number:@"last_accept_seq"] + 1;
    [self put:@"last_accept_seq" value:[NSString stringWithFormat:@"%llu", acceptSeq]];
    NSString *received = [self iso:date];
    sqlite3_stmt *insert = [self prepare:
        @"INSERT INTO revisions(source_id,event_id,revision,session_id,received_at,updated_at,role,text,text_hash,accept_seq,text_bytes) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?)"];
    [self bindEvent:insert source:source event:eventId revision:nextRevision session:session received:received role:role text:text hash:digest accept:acceptSeq bytes:bytes];
    if (sqlite3_step(insert) != SQLITE_DONE) {
        sqlite3_finalize(insert);
        if (error) *error = [self failure:@"写入修订失败，原记录未改"];
        return nil;
    }
    sqlite3_finalize(insert);
    sqlite3_stmt *view = [self prepare:
        @"INSERT INTO records(source_id,event_id,revision,session_id,received_at,updated_at,role,text,text_hash,accept_seq,text_bytes) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(source_id,event_id) DO UPDATE SET revision=excluded.revision,session_id=excluded.session_id,"
        "received_at=excluded.received_at,updated_at=excluded.updated_at,role=excluded.role,text=excluded.text,"
        "text_hash=excluded.text_hash,accept_seq=excluded.accept_seq,text_bytes=excluded.text_bytes "
        "WHERE excluded.revision>=records.revision"];
    [self bindEvent:view source:source event:eventId revision:nextRevision session:session received:received role:role text:text hash:digest accept:acceptSeq bytes:bytes];
    if (sqlite3_step(view) != SQLITE_DONE) {
        sqlite3_finalize(view);
        if (error) *error = [self failure:@"更新当前文字失败，事务将回滚"];
        return nil;
    }
    sqlite3_finalize(view);
    NSString *target = [self get:@"paired_target_id"] ?: @"";
    BOOL enqueue = policy && [self flag:@"upload_consent"] && acceptSeq >= [self number:@"upload_start_sequence"] && target.length > 0 && [self flag:@"source_bound"];
    if (enqueue) {
        sqlite3_stmt *outbox = [self prepare:
            @"INSERT INTO outbox(source_id,event_id,revision,target_id,state,attempt_count,created_at) VALUES(?,?,?,?, 'pending',0,?)"];
        sqlite3_bind_text(outbox, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(outbox, 2, eventId.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(outbox, 3, nextRevision);
        sqlite3_bind_text(outbox, 4, target.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(outbox, 5, received.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_step(outbox);
        sqlite3_finalize(outbox);
    }
    return @{@"accepted": @YES, @"duplicate": @NO, @"eventId": eventId, @"revision": @(nextRevision), @"queued": @(enqueue)};
}

- (void)bindEvent:(sqlite3_stmt *)stmt source:(NSString *)source event:(NSString *)eventId revision:(long long)revision session:(NSString *)session received:(NSString *)received role:(NSString *)role text:(NSString *)text hash:(NSString *)hash accept:(unsigned long long)accept bytes:(NSUInteger)bytes {
    sqlite3_bind_text(stmt, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, eventId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 3, revision);
    sqlite3_bind_text(stmt, 4, session.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, received.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 6, received.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 7, role.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 8, text.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 9, hash.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 10, (sqlite3_int64)accept);
    sqlite3_bind_int64(stmt, 11, (sqlite3_int64)bytes);
}

- (NSString *)eventIdForRound:(NSString *)round role:(NSString *)role session:(NSString *)session policy:(BOOL)policy {
    if (!policy) {
        NSString *legacy = round.length ? [NSString stringWithFormat:@"%@|%@", round, role] : NSUUID.UUID.UUIDString;
        return legacy.length <= 128 ? legacy : nil;
    }
    if (!round.length) return NSUUID.UUID.UUIDString;
    NSString *composed = [NSString stringWithFormat:@"%@:%@|%@", session, round, role];
    if (composed.length <= 128) return composed;
    return [@"h-" stringByAppendingString:TIOMemorySyncSHA256([composed dataUsingEncoding:NSUTF8StringEncoding])];
}

- (NSDictionary *)rejected:(NSString *)reason {
    return @{@"accepted": @NO, @"reason": reason};
}

- (void)ensureDefaults {
    if ([self get:@"settings_version"]) return;
    [self put:@"settings_version" value:@"1"];
    [self put:@"capture_enabled" value:@"0"];
    [self put:@"upload_consent" value:@"0"];
    [self put:@"upload_start_sequence" value:@"0"];
    [self put:@"upload_paused" value:@"0"];
    [self put:@"source_id" value:NSUUID.UUID.UUIDString];
    [self put:@"generation" value:@"1"];
    [self put:@"session_id" value:@""];
    [self put:@"compatibility_paused" value:@"0"];
    [self put:@"source_paused" value:@"0"];
    [self put:@"auth_paused" value:@"0"];
    [self put:@"source_bound" value:@"0"];
    [self put:@"last_accept_seq" value:@"0"];
    [self put:@"rejected_stale" value:@"0"];
    [self put:@"migration_blocked" value:@"0"];
    [self put:@"paired_origin" value:@""];
    [self put:@"paired_target_id" value:@""];
}

- (void)migrateLegacy {
    NSURL *file = [_directory URLByAppendingPathComponent:@"final-transcripts.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) return;
    NSData *data = [NSData dataWithContentsOfURL:file];
    NSString *hash = TIOMemorySyncSHA256(data ?: [NSData data]);
    if ([self countSql:@"SELECT COUNT(*) FROM migration WHERE source_hash=?" text:hash ?: @""] > 0) return;
    NSNumber *size = nil, *link = nil;
    [file getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    id rows = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    BOOL valid = !link.boolValue && size && size.unsignedLongLongValue <= TIOMemorySyncMaxBytes && [rows isKindOfClass:NSArray.class] && [rows count] <= TIOMemorySyncMaxRecords;
    if (valid) {
        for (id row in rows) {
            if (![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] || ![row[@"text"] isKindOfClass:NSString.class] || ![row[@"at"] isKindOfClass:NSString.class] || ![row[@"role"] isKindOfClass:NSString.class]) valid = NO;
        }
    }
    if (!valid) {
        [self put:@"migration_blocked" value:@"1"];
        return;
    }
    if (![self exec:@"BEGIN IMMEDIATE"]) {
        [self put:@"migration_blocked" value:@"1"];
        return;
    }
    BOOL ok = YES;
    NSString *source = [self get:@"source_id"] ?: @"";
    for (NSDictionary *row in rows) {
        NSString *text = row[@"text"];
        NSUInteger bytes = [text dataUsingEncoding:NSUTF8StringEncoding].length;
        unsigned long long acceptSeq = [self number:@"last_accept_seq"] + 1;
        [self put:@"last_accept_seq" value:[NSString stringWithFormat:@"%llu", acceptSeq]];
        sqlite3_stmt *insert = [self prepare:
            @"INSERT INTO revisions(source_id,event_id,revision,session_id,received_at,updated_at,role,text,text_hash,accept_seq,text_bytes) "
            "VALUES(?,?,1,'legacy',?,?,?,?,?,?,?)"];
        sqlite3_bind_text(insert, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 2, [row[@"id"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 3, [row[@"at"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 4, [row[@"at"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 5, [row[@"role"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 6, text.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(insert, 7, TIOMemorySyncTextHash(text).UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(insert, 8, (sqlite3_int64)acceptSeq);
        sqlite3_bind_int64(insert, 9, (sqlite3_int64)bytes);
        ok = sqlite3_step(insert) == SQLITE_DONE;
        sqlite3_finalize(insert);
        if (!ok) break;
        sqlite3_stmt *view = [self prepare:
            @"INSERT OR IGNORE INTO records(source_id,event_id,revision,session_id,received_at,updated_at,role,text,text_hash,accept_seq,text_bytes) "
            "VALUES(?,?,1,'legacy',?,?,?,?,?,?,?)"];
        sqlite3_bind_text(view, 1, source.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 2, [row[@"id"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 3, [row[@"at"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 4, [row[@"at"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 5, [row[@"role"] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 6, text.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(view, 7, TIOMemorySyncTextHash(text).UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(view, 8, (sqlite3_int64)acceptSeq);
        sqlite3_bind_int64(view, 9, (sqlite3_int64)bytes);
        ok = sqlite3_step(view) == SQLITE_DONE;
        sqlite3_finalize(view);
        if (!ok) break;
    }
    if (ok) {
        sqlite3_stmt *mark = [self prepare:@"INSERT INTO migration(source_path,source_hash,imported_count,imported_at) VALUES(?,?,?,?)"];
        sqlite3_bind_text(mark, 1, file.path.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(mark, 2, hash.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(mark, 3, (sqlite3_int64)[rows count]);
        sqlite3_bind_text(mark, 4, [self iso:NSDate.date].UTF8String, -1, SQLITE_TRANSIENT);
        ok = sqlite3_step(mark) == SQLITE_DONE;
        sqlite3_finalize(mark);
    }
    if (!ok) {
        [self exec:@"ROLLBACK"];
        [self put:@"migration_blocked" value:@"1"];
        return;
    }
    [self exec:@"COMMIT"];
    [self put:@"migration_blocked" value:@"0"];
}

- (BOOL)uploadsAllowed {
    return [self flag:@"upload_consent"] && ![self flag:@"upload_paused"] && [self flag:@"source_bound"]
        && [self get:@"paired_target_id"].length > 0 && ![self flag:@"auth_paused"]
        && ![self flag:@"compatibility_paused"] && ![self flag:@"source_paused"] && ![self flag:@"migration_blocked"];
}

- (void)failLocked:(NSString *)batchId code:(NSString *)code retry:(NSDate *)retryAt auth:(BOOL)authPause {
    sqlite3_stmt *current = [self prepare:@"SELECT attempt_count FROM batches WHERE batch_id=?"];
    sqlite3_bind_text(current, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    long long attempts = sqlite3_step(current) == SQLITE_ROW ? sqlite3_column_int64(current, 0) : 0;
    sqlite3_finalize(current);
    if (retryAt && !authPause && attempts + 1 >= (long long)TIOMemorySyncMaxAttempts) {
        retryAt = nil;
        code = @"retry_exhausted";
    }
    NSString *state = authPause ? @"auth_paused" : (retryAt ? @"retry_wait" : @"error");
    if (authPause) [self put:@"auth_paused" value:@"1"];
    sqlite3_stmt *batch = [self prepare:@"UPDATE batches SET state=?, last_error=?, next_attempt_at=?, attempt_count=attempt_count+1 WHERE batch_id=?"];
    sqlite3_bind_text(batch, 1, state.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(batch, 2, code.UTF8String, -1, SQLITE_TRANSIENT);
    if (retryAt) sqlite3_bind_text(batch, 3, [self iso:retryAt].UTF8String, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_null(batch, 3);
    sqlite3_bind_text(batch, 4, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(batch);
    sqlite3_finalize(batch);
    sqlite3_stmt *items = [self prepare:@"UPDATE outbox SET state=?, last_error=?, next_attempt_at=?, attempt_count=attempt_count+1 WHERE batch_id=?"];
    sqlite3_bind_text(items, 1, state.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(items, 2, code.UTF8String, -1, SQLITE_TRANSIENT);
    if (retryAt && !authPause) sqlite3_bind_text(items, 3, [self iso:retryAt].UTF8String, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_null(items, 3);
    sqlite3_bind_text(items, 4, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(items);
    sqlite3_finalize(items);
}

- (void)resetBatch:(NSString *)batchId {
    sqlite3_stmt *items = [self prepare:@"UPDATE outbox SET state='pending', batch_id=NULL, last_error=NULL WHERE batch_id=?"];
    sqlite3_bind_text(items, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(items);
    sqlite3_finalize(items);
    sqlite3_stmt *removeItems = [self prepare:@"DELETE FROM batch_items WHERE batch_id=?"];
    sqlite3_bind_text(removeItems, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(removeItems);
    sqlite3_finalize(removeItems);
    sqlite3_stmt *remove = [self prepare:@"DELETE FROM batches WHERE batch_id=?"];
    sqlite3_bind_text(remove, 1, batchId.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(remove);
    sqlite3_finalize(remove);
}

- (BOOL)exec:(NSString *)sql {
    return sqlite3_exec(_db, sql.UTF8String, NULL, NULL, NULL) == SQLITE_OK;
}

- (sqlite3_stmt *)prepare:(NSString *)sql {
    sqlite3_stmt *stmt = NULL;
    sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    return stmt;
}

- (NSString *)get:(NSString *)key {
    sqlite3_stmt *stmt = [self prepare:@"SELECT value FROM settings WHERE key=?"];
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
    NSString *value = sqlite3_step(stmt) == SQLITE_ROW ? [self column:stmt index:0] : nil;
    sqlite3_finalize(stmt);
    return value;
}

- (void)put:(NSString *)key value:(NSString *)value {
    sqlite3_stmt *stmt = [self prepare:@"INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"];
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, value.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

- (BOOL)flag:(NSString *)key { return [[self get:key] isEqual:@"1"]; }
- (unsigned long long)number:(NSString *)key { return strtoull([self get:key].UTF8String ?: "0", NULL, 10); }

- (long long)countSql:(NSString *)sql text:(NSString *)text {
    sqlite3_stmt *stmt = [self prepare:sql];
    if (text) sqlite3_bind_text(stmt, 1, text.UTF8String, -1, SQLITE_TRANSIENT);
    long long value = sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
    sqlite3_finalize(stmt);
    return value;
}

- (NSString *)textSql:(NSString *)sql {
    sqlite3_stmt *stmt = [self prepare:sql];
    NSString *value = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL ? [self column:stmt index:0] : nil;
    sqlite3_finalize(stmt);
    return value;
}

- (NSString *)column:(sqlite3_stmt *)stmt index:(int)index {
    const unsigned char *text = sqlite3_column_text(stmt, index);
    return text ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

- (long long)columnInt:(sqlite3_stmt *)stmt index:(int)index { return sqlite3_column_int64(stmt, index); }

- (NSString *)iso:(NSDate *)date {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:date];
}

- (NSError *)failure:(NSString *)message {
    return [NSError errorWithDomain:TIOMemorySyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
