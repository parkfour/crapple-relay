#import "MessageObserver.h"
#import "IMServiceManager.h"
#import "RelayLogger.h"
#import <sqlite3.h>

@interface MessageObserver ()
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) int64_t lastProcessedRowID;
@property (nonatomic, strong) NSMutableSet<NSString *> *processedMessageGUIDs;
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
        _processedMessageGUIDs = [NSMutableSet set];
        _lastProcessedRowID = 0;
        _isRunning = NO;
    }
    return self;
}

- (void)startWithWebhookURL:(NSString *)webhookURL
               webhookToken:(NSString *)webhookToken
               pollInterval:(NSTimeInterval)interval {
    if (self.isRunning) return;
    
    self.webhookURL = webhookURL;
    self.webhookToken = webhookToken;
    self.isRunning = YES;
    
    // Register IMCore notification observers
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatRegistryMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatRegistryMessageReceivedNotification" object:nil];
    
    NSLog(@"[+] Real-time incoming IMCore message observer registered.");
    
    // Initialize chat.db SQLite watcher
    [self checkDatabaseForNewMessages];
    
    // Schedule periodic chat.db polling timer
    uint64_t intervalNs = (uint64_t)(interval * NSEC_PER_SEC);
    if (intervalNs == 0) intervalNs = 1000 * NSEC_PER_MSEC;
    
    self.dbPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.dbPollTimer, dispatch_time(DISPATCH_TIME_NOW, intervalNs), intervalNs, 100 * NSEC_PER_MSEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.dbPollTimer, ^{
        [weakSelf checkDatabaseForNewMessages];
    });
    dispatch_resume(self.dbPollTimer);
    
    NSLog(@"[+] Real-time chat.db SQLite observer active (polling interval: %.1fs).", interval > 0 ? interval : 1.0);
    NSLog(@"[+] Outgoing webhook configured for %@.", self.webhookURL);
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

#pragma mark - IMCore Notification Handling

- (void)handleMessageNotification:(NSNotification *)note {
    IMMessage *msg = nil;
    IMChat *chat = nil;
    
    if ([note.object isKindOfClass:[IMChat class]]) {
        chat = (IMChat *)note.object;
    }
    
    if (note.userInfo) {
        if ([note.userInfo[@"__kIMChatValueKey"] isKindOfClass:[IMMessage class]]) {
            msg = (IMMessage *)note.userInfo[@"__kIMChatValueKey"];
        } else if ([note.userInfo[@"message"] isKindOfClass:[IMMessage class]]) {
            msg = (IMMessage *)note.userInfo[@"message"];
        } else if ([note.userInfo[@"__kIMChatRegistryMessageSentMessageKey"] isKindOfClass:[IMMessage class]]) {
            msg = (IMMessage *)note.userInfo[@"__kIMChatRegistryMessageSentMessageKey"];
        } else {
            for (id key in note.userInfo) {
                id val = note.userInfo[key];
                if ([val isKindOfClass:[IMMessage class]]) {
                    msg = (IMMessage *)val;
                    break;
                }
            }
        }
    }
    
    if (!msg && [note.object isKindOfClass:[IMMessage class]]) {
        msg = (IMMessage *)note.object;
    }
    
    if (!msg) {
        // Fall back to polling database immediately
        [self checkDatabaseForNewMessages];
        return;
    }
    
    [self processIncomingMessage:msg chat:chat];
}

- (void)processIncomingMessage:(IMMessage *)message chat:(nullable IMChat *)chat {
    if (message.isFromMe) {
        return; // Filter out messages sent from the user's account
    }
    
    NSString *guid = message.guid;
    if (guid.length > 0) {
        if ([self.processedMessageGUIDs containsObject:guid]) {
            return; // Duplicate event
        }
        [self.processedMessageGUIDs addObject:guid];
    }
    
    // Participant / author identification
    NSString *fromHandle = message.sender.ID ?: message.sender.displayID ?: @"";
    if (fromHandle.length == 0 && chat && chat.recipient) {
        fromHandle = chat.recipient.ID ?: chat.recipient.normalizedID ?: @"";
    }
    
    BOOL isGroup = NO;
    NSString *chatIdentifier = @"";
    NSString *chatGUID = @"";
    NSString *groupName = @"";
    
    if (chat) {
        if ([chat respondsToSelector:@selector(isGroupChat)]) {
            isGroup = [chat isGroupChat];
        }
        chatIdentifier = chat.chatIdentifier ?: @"";
        chatGUID = chat.guid ?: @"";
        groupName = chat.displayName ?: @"";
    }
    
    if (!isGroup && ([chatGUID containsString:@";+;"] || [chatIdentifier hasPrefix:@"chat"])) {
        isGroup = YES;
    }
    
    // For group messages: route under the group chat identifier (e.g. "chat123456789012345678")
    // For 1-on-1: route under the remote contact handle (e.g. "+15551234567")
    NSString *sender = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : fromHandle;
    if (sender.length == 0) {
        sender = chatIdentifier.length > 0 ? chatIdentifier : fromHandle;
    }
    
    // Message text body
    NSString *body = message.plainBody ?: message.text.string ?: @"";
    body = [body stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Media Attachments
    NSString *attachmentBase64 = @"";
    NSString *attachmentMime = @"";
    NSString *attachmentName = @"";
    
    NSArray<NSString *> *guids = message.fileTransferGUIDs;
    if (guids && guids.count > 0) {
        NSString *transferGUID = guids[0];
        IMFileTransfer *transfer = [[IMFileTransferCenter sharedInstance] transferForGUID:transferGUID];
        if (transfer) {
            if (transfer.filename) attachmentName = transfer.filename;
            if (transfer.mimeType) attachmentMime = transfer.mimeType;
            
            NSString *filePath = transfer.localPath;
            if (!filePath && transfer.localURL) {
                filePath = [transfer.localURL path];
            }
            if (filePath && [[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                NSData *data = [NSData dataWithContentsOfFile:filePath];
                if (data) {
                    attachmentBase64 = [data base64EncodedStringWithOptions:0];
                }
            }
        }
    }
    
    NSString *groupChatID = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : @"";
    NSString *correspondent = fromHandle ?: @"";
    
    NSArray<NSString *> *participants = [[IMServiceManager sharedInstance] participantsForChat:chat chatIdentifier:chatIdentifier chatGUID:chatGUID];
    if (participants.count == 0 && fromHandle.length > 0) {
        participants = @[fromHandle];
    }
    
    NSDictionary *payload = @{
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
        @"message": body ?: @"",
        @"attachment_base64": attachmentBase64 ?: @"",
        @"attachment_mime": attachmentMime ?: @"",
        @"attachment_name": attachmentName ?: @""
    };
    
    NSLog(@"[+] Captured incoming iMessage from '%@' in '%@' (is_group: %d): '%@' (media: %@, %lu bytes base64)",
          fromHandle, sender, isGroup, body, attachmentName.length > 0 ? attachmentName : @"none", (unsigned long)attachmentBase64.length);
    
    [self dispatchWebhookWithPayload:payload];
}

#pragma mark - SQLite chat.db Observation

- (void)checkDatabaseForNewMessages {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return;
    
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    
    // Initial bootstrap: find current max ROWID
    if (self.lastProcessedRowID == 0) {
        sqlite3_stmt *maxStmt = NULL;
        const char *maxSql = "SELECT MAX(ROWID) FROM message";
        if (sqlite3_prepare_v2(db, maxSql, -1, &maxStmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(maxStmt) == SQLITE_ROW) {
                int64_t maxRow = sqlite3_column_int64(maxStmt, 0);
                self.lastProcessedRowID = maxRow;
                NSLog(@"[+] [chat.db] Initialized message watcher starting at ROWID %lld", maxRow);
            }
            sqlite3_finalize(maxStmt);
        }
        sqlite3_close(db);
        return;
    }
    
    const char *query = "SELECT m.ROWID, m.guid, m.text, h.id, m.is_from_me, m.date, "
                        "       att.filename, att.mime_type, att.transfer_name, "
                        "       c.chat_identifier, c.guid, c.style, c.display_name, c.group_id "
                        "FROM message m "
                        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
                        "LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id "
                        "LEFT JOIN chat c ON cmj.chat_id = c.ROWID "
                        "LEFT JOIN message_attachment_join maj ON m.ROWID = maj.message_id "
                        "LEFT JOIN attachment att ON maj.attachment_id = att.ROWID "
                        "WHERE m.ROWID > ? "
                        "ORDER BY m.ROWID ASC";
    
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, self.lastProcessedRowID);
        
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int64_t rowID = sqlite3_column_int64(stmt, 0);
            if (rowID > self.lastProcessedRowID) {
                self.lastProcessedRowID = rowID;
            }
            
            int isFromMe = sqlite3_column_int(stmt, 4);
            if (isFromMe == 1) {
                continue; // Ignore outgoing messages
            }
            
            const char *guidC = (const char *)sqlite3_column_text(stmt, 1);
            NSString *guid = guidC ? [NSString stringWithUTF8String:guidC] : @"";
            
            if (guid.length > 0) {
                if ([self.processedMessageGUIDs containsObject:guid]) {
                    continue; // Already processed
                }
                [self.processedMessageGUIDs addObject:guid];
            }
            
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
            
            // For group messages: route under the group chat identifier (e.g. "chat123456789012345678")
            // For 1-on-1: route under the remote contact handle (e.g. "+15551234567")
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
                    if (data) {
                        attachmentBase64 = [data base64EncodedStringWithOptions:0];
                    }
                }
                
                const char *mimeC = (const char *)sqlite3_column_text(stmt, 7);
                if (mimeC) attachmentMime = [NSString stringWithUTF8String:mimeC];
                
                const char *nameC = (const char *)sqlite3_column_text(stmt, 8);
                if (nameC) {
                    attachmentName = [NSString stringWithUTF8String:nameC];
                } else {
                    attachmentName = [filePath lastPathComponent] ?: @"";
                }
            }
            
            NSString *groupChatID = (isGroup && chatIdentifier.length > 0) ? chatIdentifier : @"";
            NSString *correspondent = fromHandle ?: @"";
            
            NSArray<NSString *> *participants = [[IMServiceManager sharedInstance] participantsForChat:nil chatIdentifier:chatIdentifier chatGUID:chatGUID];
            if (participants.count == 0 && fromHandle.length > 0) {
                participants = @[fromHandle];
            }
            
            NSDictionary *payload = @{
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
            
            NSLog(@"[+] [chat.db] Captured incoming iMessage (ROWID %lld, GUID %@) from '%@' in '%@' (is_group: %d): '%@'",
                  rowID, guid, fromHandle, sender, isGroup, text);
            [self dispatchWebhookWithPayload:payload];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

#pragma mark - Webhook Dispatch

- (void)dispatchWebhookWithPayload:(NSDictionary *)payload {
    NSURL *url = [NSURL URLWithString:self.webhookURL];
    if (!url) {
        NSLog(@"[ERROR] Invalid webhook URL: %@", self.webhookURL);
        return;
    }
    
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (jsonError || !bodyData) {
        NSLog(@"[ERROR] Failed to serialize webhook payload: %@", jsonError);
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
    
    NSLog(@"[+] Dispatching webhook POST to %@ for sender '%@' (is_group: %d, from: '%@')...",
          self.webhookURL, payload[@"sender"], [payload[@"is_group"] boolValue], payload[@"from"] ?: @"");
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[ERROR] Webhook POST to %@ failed: %@", self.webhookURL, error.localizedDescription);
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSLog(@"[+] Webhook POST to %@ completed with HTTP %ld", self.webhookURL, (long)httpResp.statusCode);
    }];
    [task resume];
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
                        "       c.chat_identifier, c.guid, c.style, c.display_name, c.group_id "
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
        [self dispatchWebhookWithPayload:payload];
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
