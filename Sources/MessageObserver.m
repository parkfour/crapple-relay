#import "MessageObserver.h"
#import "IMServiceManager.h"
#import "RelayLogger.h"
#import <sqlite3.h>

@interface MessageObserver ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) int64_t lastDeliveredRowID;
@property (nonatomic, assign) BOOL isDelivering;
@property (nonatomic, assign) NSUInteger consecutiveFailures;
@property (nonatomic, strong, nullable) NSDate *nextRetryAllowedDate;
@property (nonatomic, strong) dispatch_source_t dbPollTimer;
@end

@implementation MessageObserver

+ (instancetype)sharedInstance {
    static MessageObserver *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[MessageObserver alloc] init];
    });
    return s_instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastDeliveredRowID = 0;
        _isRunning = NO;
        _isDelivering = NO;
        _consecutiveFailures = 0;
        _nextRetryAllowedDate = nil;
    }
    return self;
}

- (int64_t)lastProcessedRowID {
    return self.lastDeliveredRowID;
}

#pragma mark - State Persistence

- (NSString *)stateFilePath {
    return [@"~/.crapple_relay_state.json" stringByExpandingTildeInPath];
}

- (int64_t)fetchMaxRowIDFromDatabase {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return 0;
    
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return 0;
    }
    
    int64_t maxRow = 0;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT MAX(ROWID) FROM message";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            maxRow = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return maxRow;
}

- (void)loadState {
    NSString *statePath = [self stateFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:statePath]) {
        NSData *data = [NSData dataWithContentsOfFile:statePath];
        if (data) {
            NSError *err = nil;
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
            if ([dict isKindOfClass:[NSDictionary class]] && dict[@"last_delivered_rowid"]) {
                self.lastDeliveredRowID = [dict[@"last_delivered_rowid"] longLongValue];
                NSLog(@"[+] [State] Loaded persistent last_delivered_rowid %lld from %@", self.lastDeliveredRowID, statePath);
                return;
            }
        }
    }
    
    // First run with state file: initialize to current MAX(ROWID) in chat.db
    int64_t maxRow = [self fetchMaxRowIDFromDatabase];
    self.lastDeliveredRowID = maxRow;
    NSLog(@"[+] [State] Initialized state to MAX(ROWID) = %lld (written to %@)", maxRow, statePath);
    [self saveState];
}

- (void)saveState {
    NSString *statePath = [self stateFilePath];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    NSString *isoDate = [formatter stringFromDate:[NSDate date]];
    
    NSDictionary *dict = @{
        @"last_delivered_rowid": @(self.lastDeliveredRowID),
        @"updated_at": isoDate
    };
    
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&err];
    if (data) {
        [data writeToFile:statePath atomically:YES];
    } else {
        NSLog(@"[ERROR] Failed to save state to %@: %@", statePath, err);
    }
}

- (NSUInteger)pendingMessageCount {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return 0;
    
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return 0;
    }
    
    NSUInteger count = 0;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT COUNT(DISTINCT m.ROWID) FROM message m WHERE m.is_from_me = 0 AND m.ROWID > ?";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, self.lastDeliveredRowID);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            count = (NSUInteger)sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return count;
}

- (NSDictionary *)queueStatusInfo {
    NSTimeInterval retryIn = 0;
    if (self.nextRetryAllowedDate) {
        retryIn = [self.nextRetryAllowedDate timeIntervalSinceNow];
        if (retryIn < 0) retryIn = 0;
    }
    
    return @{
        @"last_delivered_rowid": @(self.lastDeliveredRowID),
        @"pending_count": @([self pendingMessageCount]),
        @"consecutive_failures": @(self.consecutiveFailures),
        @"in_flight": @(self.isDelivering),
        @"next_retry_in_seconds": @((NSInteger)ceil(retryIn)),
        @"state_file": [self stateFilePath]
    };
}

- (NSTimeInterval)backoffDelayForFailures:(NSUInteger)failures {
    if (failures <= 1) return 3.0;
    if (failures == 2) return 5.0;
    if (failures == 3) return 10.0;
    if (failures == 4) return 20.0;
    return 30.0;
}

- (void)resetBackoffAndDrainQueue {
    self.consecutiveFailures = 0;
    self.nextRetryAllowedDate = nil;
    [self processPendingQueue];
}

- (void)setDeliveredRowID:(int64_t)rowID {
    self.lastDeliveredRowID = rowID;
    [self saveState];
    [self resetBackoffAndDrainQueue];
}

#pragma mark - Lifecycle

- (void)startWithWebhookURL:(NSString *)webhookURL
               webhookToken:(NSString *)webhookToken
               pollInterval:(NSTimeInterval)interval {
    if (self.isRunning) return;
    
    self.webhookURL = webhookURL;
    self.webhookToken = webhookToken;
    self.isRunning = YES;
    
    // Load state
    [self loadState];
    
    // Register IMCore notification observers
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatRegistryMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatRegistryMessageReceivedNotification" object:nil];
    
    NSLog(@"[+] Real-time incoming IMCore message observer registered.");
    
    // Initial queue check
    [self processPendingQueue];
    
    // Schedule periodic chat.db polling timer
    uint64_t intervalNs = (uint64_t)(interval * NSEC_PER_SEC);
    if (intervalNs == 0) intervalNs = 1000 * NSEC_PER_MSEC;
    
    self.dbPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.dbPollTimer, dispatch_time(DISPATCH_TIME_NOW, intervalNs), intervalNs, 100 * NSEC_PER_MSEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.dbPollTimer, ^{
        [weakSelf processPendingQueue];
    });
    dispatch_resume(self.dbPollTimer);
    
    NSLog(@"[+] Real-time chat.db SQLite observer active (polling interval: %.1fs).", interval > 0 ? interval : 1.0);
    NSLog(@"[+] Outgoing webhook configured for %@ (last_delivered_rowid: %lld, pending: %lu).",
          self.webhookURL, self.lastDeliveredRowID, (unsigned long)[self pendingMessageCount]);
}

- (void)stop {
    if (!self.isRunning) return;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.dbPollTimer) {
        dispatch_source_cancel(self.dbPollTimer);
        self.dbPollTimer = nil;
    }
    self.isRunning = NO;
    NSLog(@"[+] MessageObserver stopped.");
}

- (void)checkDatabaseForNewMessages {
    [self processPendingQueue];
}

- (void)handleMessageNotification:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[+] IMCore notification received (%@) - triggering queue processing.", note.name);
        [self processPendingQueue];
        
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf processPendingQueue];
        });
    });
}

#pragma mark - FIFO Queue Processing

- (void)processPendingQueue {
    if (!self.isRunning) return;
    if (self.isDelivering) return;
    if (self.nextRetryAllowedDate && [self.nextRetryAllowedDate timeIntervalSinceNow] > 0) {
        return;
    }
    
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return;
    
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    
    const char *query = "SELECT m.ROWID, m.guid, m.text, h.id, m.is_from_me, m.date, "
                        "       att.filename, att.mime_type, att.transfer_name, "
                        "       c.chat_identifier, c.guid, c.style, c.display_name "
                        "FROM message m "
                        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
                        "LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id "
                        "LEFT JOIN chat c ON cmj.chat_id = c.ROWID "
                        "LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id "
                        "LEFT JOIN attachment att ON maj.attachment_id = att.ROWID "
                        "WHERE m.ROWID > ? "
                        "ORDER BY m.ROWID ASC";
    
    sqlite3_stmt *stmt = NULL;
    int64_t targetRowID = 0;
    NSString *targetGUID = @"";
    NSDictionary *targetPayload = nil;
    BOOL stateChanged = NO;
    
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, self.lastDeliveredRowID);
        
        NSString *attBase64 = @"";
        NSString *attMime = @"";
        NSString *attName = @"";
        
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int64_t rowID = sqlite3_column_int64(stmt, 0);
            int isFromMe = sqlite3_column_int(stmt, 4);
            
            if (isFromMe == 1) {
                if (targetRowID == 0) {
                    // Fast-forward cursor past user's own sent message
                    if (rowID > self.lastDeliveredRowID) {
                        self.lastDeliveredRowID = rowID;
                        stateChanged = YES;
                    }
                    continue;
                } else {
                    // We already found our next incoming message to deliver; stop scanning
                    break;
                }
            }
            
            // isFromMe == 0 (Incoming message)
            if (targetRowID == 0) {
                targetRowID = rowID;
                
                const char *guidC = (const char *)sqlite3_column_text(stmt, 1);
                targetGUID = guidC ? [NSString stringWithUTF8String:guidC] : @"";
                
                const char *textC = (const char *)sqlite3_column_text(stmt, 2);
                NSString *text = textC ? [NSString stringWithUTF8String:textC] : @"";
                text = [text stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
                text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                const char *fromC = (const char *)sqlite3_column_text(stmt, 3);
                NSString *fromHandle = fromC ? [NSString stringWithUTF8String:fromC] : @"";
                
                const char *chatIdentC = (const char *)sqlite3_column_text(stmt, 9);
                NSString *chatIdentifier = chatIdentC ? [NSString stringWithUTF8String:chatIdentC] : @"";
                
                const char *chatGuidC = (const char *)sqlite3_column_text(stmt, 10);
                NSString *chatGUID = chatGuidC ? [NSString stringWithUTF8String:chatGuidC] : @"";
                
                int chatStyle = sqlite3_column_int(stmt, 11);
                
                const char *dispNameC = (const char *)sqlite3_column_text(stmt, 12);
                NSString *groupName = dispNameC ? [NSString stringWithUTF8String:dispNameC] : @"";
                
                BOOL isGroup = (chatStyle == 43) || [chatGUID containsString:@";+;"] || [chatIdentifier hasPrefix:@"chat"];
                
                NSString *sender = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : fromHandle;
                if (sender.length == 0) {
                    sender = chatIdentifier.length > 0 ? chatIdentifier : fromHandle;
                }
                
                NSString *groupChatID = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : @"";
                NSString *correspondent = fromHandle ?: @"";
                
                NSArray<NSString *> *participants = [[IMServiceManager sharedInstance] participantsForChat:nil chatIdentifier:chatIdentifier chatGUID:chatGUID];
                if (participants.count == 0 && fromHandle.length > 0) {
                    participants = @[fromHandle];
                }
                
                // Read attachment if present in this row
                const char *attFileC = (const char *)sqlite3_column_text(stmt, 6);
                if (attFileC) {
                    NSString *rawPath = [NSString stringWithUTF8String:attFileC];
                    NSString *filePath = [rawPath stringByExpandingTildeInPath];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                        NSData *data = [NSData dataWithContentsOfFile:filePath];
                        if (data) attBase64 = [data base64EncodedStringWithOptions:0];
                    }
                    const char *mimeC = (const char *)sqlite3_column_text(stmt, 7);
                    if (mimeC) attMime = [NSString stringWithUTF8String:mimeC];
                    const char *nameC = (const char *)sqlite3_column_text(stmt, 8);
                    if (nameC) attName = [NSString stringWithUTF8String:nameC];
                    else attName = [filePath lastPathComponent] ?: @"";
                }
                
                targetPayload = @{
                    @"sender": sender ?: @"",
                    @"group_chat_id": groupChatID ?: @"",
                    @"correspondent": correspondent ?: @"",
                    @"from": fromHandle ?: @"",
                    @"participant": fromHandle ?: @"",
                    @"participants": participants ?: @[],
                    @"is_group": @(isGroup),
                    @"chat_identifier": chatIdentifier ?: @"",
                    @"chat_guid": chatGUID ?: @"",
                    @"group_name": groupName ?: @"",
                    @"message": text ?: @"",
                    @"attachment_base64": attBase64 ?: @"",
                    @"attachment_mime": attMime ?: @"",
                    @"attachment_name": attName ?: @""
                };
            } else if (targetRowID == rowID) {
                // Secondary join row for the same incoming message (e.g. additional attachment)
                if (attBase64.length == 0) {
                    const char *attFileC = (const char *)sqlite3_column_text(stmt, 6);
                    if (attFileC) {
                        NSString *rawPath = [NSString stringWithUTF8String:attFileC];
                        NSString *filePath = [rawPath stringByExpandingTildeInPath];
                        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                            NSData *data = [NSData dataWithContentsOfFile:filePath];
                            if (data) attBase64 = [data base64EncodedStringWithOptions:0];
                        }
                        const char *mimeC = (const char *)sqlite3_column_text(stmt, 7);
                        if (mimeC) attMime = [NSString stringWithUTF8String:mimeC];
                        const char *nameC = (const char *)sqlite3_column_text(stmt, 8);
                        if (nameC) attName = [NSString stringWithUTF8String:nameC];
                        else attName = [filePath lastPathComponent] ?: @"";
                        
                        NSMutableDictionary *mPayload = [targetPayload mutableCopy];
                        mPayload[@"attachment_base64"] = attBase64 ?: @"";
                        mPayload[@"attachment_mime"] = attMime ?: @"";
                        mPayload[@"attachment_name"] = attName ?: @"";
                        targetPayload = mPayload;
                    }
                }
            } else {
                // Reached next distinct message; stop scanning
                break;
            }
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    
    if (stateChanged) {
        [self saveState];
    }
    
    if (targetRowID > 0 && targetPayload) {
        self.isDelivering = YES;
        NSLog(@"[+] [Queue] Attempting delivery of ROWID %lld (%@) from '%@'...",
              targetRowID, targetGUID, targetPayload[@"sender"]);
        
        __weak typeof(self) weakSelf = self;
        [self dispatchWebhookWithPayload:targetPayload
                                   rowID:targetRowID
                              completion:^(BOOL success, NSInteger statusCode, NSError * _Nullable error) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            if (success) {
                NSLog(@"[+] [Queue] Delivery succeeded for ROWID %lld (HTTP %ld). Advancing cursor.", targetRowID, (long)statusCode);
                strongSelf.lastDeliveredRowID = targetRowID;
                [strongSelf saveState];
                strongSelf.consecutiveFailures = 0;
                strongSelf.nextRetryAllowedDate = nil;
                strongSelf.isDelivering = NO;
                
                // Immediately deliver next queued message if any
                [strongSelf processPendingQueue];
            } else {
                strongSelf.consecutiveFailures++;
                strongSelf.isDelivering = NO;
                NSTimeInterval delay = [strongSelf backoffDelayForFailures:strongSelf.consecutiveFailures];
                strongSelf.nextRetryAllowedDate = [NSDate dateWithTimeIntervalSinceNow:delay];
                NSLog(@"[!] [Queue] Delivery failed for ROWID %lld (HTTP %ld, error: %@). Retrying in %.0fs (failure #%lu). Cursor held at %lld.",
                      targetRowID, (long)statusCode, error ? error.localizedDescription : @"Unknown error", delay, (unsigned long)strongSelf.consecutiveFailures, strongSelf.lastDeliveredRowID);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf processPendingQueue];
                });
            }
        }];
    }
}

#pragma mark - Webhook Dispatch

- (void)dispatchWebhookWithPayload:(NSDictionary *)payload
                             rowID:(int64_t)rowID
                        completion:(void (^ _Nullable)(BOOL success, NSInteger statusCode, NSError * _Nullable error))completion {
    NSURL *url = [NSURL URLWithString:self.webhookURL];
    if (!url) {
        NSLog(@"[ERROR] Invalid webhook URL: %@", self.webhookURL);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, 0, [NSError errorWithDomain:@"MessageObserver" code:400 userInfo:@{NSLocalizedDescriptionKey: @"Invalid webhook URL"}]);
            });
        }
        return;
    }
    
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (jsonError || !bodyData) {
        NSLog(@"[ERROR] Failed to serialize webhook payload: %@", jsonError);
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, 0, jsonError);
            });
        }
        return;
    }
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (self.webhookToken && self.webhookToken.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", self.webhookToken] forHTTPHeaderField:@"Authorization"];
    }
    [req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:10.0];
    
    if (rowID > 0) {
        NSLog(@"[+] Dispatching webhook POST to %@ for ROWID %lld, sender '%@' (is_group: %d, from: '%@')...",
              self.webhookURL, rowID, payload[@"sender"], [payload[@"is_group"] boolValue], payload[@"from"] ?: @"");
    } else {
        NSLog(@"[+] Dispatching synthetic webhook POST to %@ for sender '%@'...",
              self.webhookURL, payload[@"sender"]);
    }
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSInteger statusCode = 0;
        BOOL success = NO;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)response statusCode];
            if (statusCode >= 200 && statusCode < 300) {
                success = YES;
            }
        }
        
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, statusCode, error);
            });
        }
    }];
    [task resume];
}

- (void)dispatchWebhookWithPayload:(NSDictionary *)payload {
    [self dispatchWebhookWithPayload:payload rowID:0 completion:nil];
}

- (nullable NSDictionary *)retryLastIncomingMessageWithError:(NSError **)error {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        if (error) {
            *error = [NSError errorWithDomain:@"MessageObserver" code:201 userInfo:@{NSLocalizedDescriptionKey: @"Unable to open chat.db"}];
        }
        return nil;
    }
    
    const char *query = "SELECT m.ROWID, m.guid, m.text, h.id, m.is_from_me, m.date, "
                        "       att.filename, att.mime_type, att.transfer_name, "
                        "       c.chat_identifier, c.guid, c.style, c.display_name "
                        "FROM message m "
                        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
                        "LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id "
                        "LEFT JOIN chat c ON cmj.chat_id = c.ROWID "
                        "LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id "
                        "LEFT JOIN attachment att ON maj.attachment_id = att.ROWID "
                        "WHERE m.is_from_me = 0 "
                        "ORDER BY m.ROWID DESC LIMIT 1";
    
    sqlite3_stmt *stmt = NULL;
    NSDictionary *payload = nil;
    NSString *guid = @"";
    int64_t rowID = 0;
    
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            rowID = sqlite3_column_int64(stmt, 0);
            const char *guidC = (const char *)sqlite3_column_text(stmt, 1);
            if (guidC) guid = [NSString stringWithUTF8String:guidC];
            
            const char *textC = (const char *)sqlite3_column_text(stmt, 2);
            NSString *text = textC ? [NSString stringWithUTF8String:textC] : @"";
            text = [text stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            const char *fromC = (const char *)sqlite3_column_text(stmt, 3);
            NSString *fromHandle = fromC ? [NSString stringWithUTF8String:fromC] : @"";
            
            const char *chatIdentC = (const char *)sqlite3_column_text(stmt, 9);
            NSString *chatIdentifier = chatIdentC ? [NSString stringWithUTF8String:chatIdentC] : @"";
            
            const char *chatGuidC = (const char *)sqlite3_column_text(stmt, 10);
            NSString *chatGUID = chatGuidC ? [NSString stringWithUTF8String:chatGuidC] : @"";
            
            int chatStyle = sqlite3_column_int(stmt, 11);
            
            const char *dispNameC = (const char *)sqlite3_column_text(stmt, 12);
            NSString *groupName = dispNameC ? [NSString stringWithUTF8String:dispNameC] : @"";
            
            BOOL isGroup = (chatStyle == 43) || [chatGUID containsString:@";+;"] || [chatIdentifier hasPrefix:@"chat"];
            
            NSString *sender = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : fromHandle;
            if (sender.length == 0) {
                sender = chatIdentifier.length > 0 ? chatIdentifier : fromHandle;
            }
            
            NSString *attachmentBase64 = @"";
            NSString *attachmentMime = @"";
            NSString *attachmentName = @"";
            
            const char *attFileC = (const char *)sqlite3_column_text(stmt, 6);
            if (attFileC) {
                NSString *rawPath = [NSString stringWithUTF8String:attFileC];
                NSString *filePath = [rawPath stringByExpandingTildeInPath];
                if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                    NSData *data = [NSData dataWithContentsOfFile:filePath];
                    if (data) attachmentBase64 = [data base64EncodedStringWithOptions:0];
                }
                const char *mimeC = (const char *)sqlite3_column_text(stmt, 7);
                if (mimeC) attachmentMime = [NSString stringWithUTF8String:mimeC];
                const char *nameC = (const char *)sqlite3_column_text(stmt, 8);
                if (nameC) attachmentName = [NSString stringWithUTF8String:nameC];
                else attachmentName = [filePath lastPathComponent] ?: @"";
            }
            
            NSString *groupChatID = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : @"";
            NSString *correspondent = fromHandle ?: @"";
            
            NSArray<NSString *> *participants = [[IMServiceManager sharedInstance] participantsForChat:nil chatIdentifier:chatIdentifier chatGUID:chatGUID];
            if (participants.count == 0 && fromHandle.length > 0) {
                participants = @[fromHandle];
            }
            
            payload = @{
                @"sender": sender ?: @"",
                @"group_chat_id": groupChatID ?: @"",
                @"correspondent": correspondent ?: @"",
                @"from": fromHandle ?: @"",
                @"participant": fromHandle ?: @"",
                @"participants": participants ?: @[],
                @"is_group": @(isGroup),
                @"chat_identifier": chatIdentifier ?: @"",
                @"chat_guid": chatGUID ?: @"",
                @"group_name": groupName ?: @"",
                @"message": text ?: @"",
                @"attachment_base64": attachmentBase64 ?: @"",
                @"attachment_mime": attachmentMime ?: @"",
                @"attachment_name": attachmentName ?: @""
            };
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    
    if (payload) {
        NSLog(@"[+] [Retry Webhook] Re-dispatching message (ROWID %lld, GUID %@) from '%@'...", rowID, guid, payload[@"sender"]);
        [self dispatchWebhookWithPayload:payload rowID:rowID completion:nil];
        return @{
            @"status": @"retrying",
            @"rowid": @(rowID),
            @"guid": guid,
            @"payload": payload,
            @"webhook_url": self.webhookURL
        };
    }
    
    if (error) {
        *error = [NSError errorWithDomain:@"MessageObserver" code:202 userInfo:@{NSLocalizedDescriptionKey: @"No incoming messages found to retry"}];
    }
    return nil;
}

@end
