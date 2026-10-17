#import "HTTPServer.h"
#import "IMServiceManager.h"
#import "MessageObserver.h"
#import "RelayLogger.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <sqlite3.h>

#ifndef RELAY_VERSION
#define RELAY_VERSION "v0.1.0"
#endif

#ifndef RELAY_COMMIT_HASH
#define RELAY_COMMIT_HASH "unknown"
#endif

@interface HTTPServer ()
@property (nonatomic, assign) int serverFd;
@property (nonatomic, strong) dispatch_source_t listenSource;
@property (nonatomic, assign) BOOL isRunning;
@end

@implementation HTTPServer

+ (NSString *)relayVersion {
    return [NSString stringWithUTF8String:RELAY_VERSION];
}

+ (NSString *)relayGitCommit {
    NSString *baked = [NSString stringWithUTF8String:RELAY_COMMIT_HASH];
    if (baked.length > 0 && ![baked isEqualToString:@"unknown"]) {
        return baked;
    }
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/git";
    task.arguments = @[@"rev-parse", @"HEAD"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        outStr = [outStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (outStr.length > 0) {
            return outStr;
        }
    } @catch (NSException *e) {}
    return @"unknown";
}

+ (NSString *)formattedRelayVersion {
    NSString *ver = [self relayVersion];
    NSString *commit = [self relayGitCommit];
    NSString *shortCommit = commit.length >= 8 ? [commit substringToIndex:8] : commit;
    return [NSString stringWithFormat:@"%@-%@", ver, shortCommit];
}

+ (NSString *)resolveDefaultIP {
    struct ifaddrs *interfaces = NULL;
    NSString *detectedIP = nil;
    
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_addr && temp->ifa_addr->sa_family == AF_INET) {
                char ip[INET_ADDRSTRLEN];
                struct sockaddr_in *addr = (struct sockaddr_in *)temp->ifa_addr;
                inet_ntop(AF_INET, &(addr->sin_addr), ip, sizeof(ip));
                NSString *ipStr = [NSString stringWithUTF8String:ip];
                
                // Prioritize private mesh interfaces (Nebula 10.169.x or Tailscale 100.x)
                if ([ipStr hasPrefix:@"10.169."] || [ipStr hasPrefix:@"100."]) {
                    detectedIP = ipStr;
                    break;
                }
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    
    return detectedIP ?: @"127.0.0.1";
}

- (instancetype)initWithHost:(nullable NSString *)host
                        port:(int)port
                 bearerToken:(NSString *)bearerToken {
    self = [super init];
    if (self) {
        _host = (host && host.length > 0) ? host : [HTTPServer resolveDefaultIP];
        _port = port > 0 ? port : 5569;
        _bearerToken = bearerToken;
        _serverFd = -1;
        _isRunning = NO;
    }
    return self;
}

- (BOOL)start {
    if (self.isRunning) return YES;
    
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[ERROR] Failed to create socket: %s", strerror(errno));
        return NO;
    }
    
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(self.port);
    
    if (inet_pton(AF_INET, [self.host UTF8String], &addr.sin_addr) <= 0) {
        NSLog(@"[ERROR] Invalid IP address format: %@", self.host);
        close(fd);
        return NO;
    }
    
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[ERROR] Failed to bind to %@:%d: %s", self.host, self.port, strerror(errno));
        close(fd);
        return NO;
    }
    
    if (listen(fd, 128) < 0) {
        NSLog(@"[ERROR] Failed to listen on socket: %s", strerror(errno));
        close(fd);
        return NO;
    }
    
    self.serverFd = fd;
    dispatch_queue_t queue = dispatch_get_main_queue();
    self.listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.listenSource, ^{
        [weakSelf handleIncomingConnection];
    });
    
    dispatch_resume(self.listenSource);
    self.isRunning = YES;
    NSLog(@"[+] Relay HTTP listener securely bound to http://%@:%d", self.host, self.port);
    NSLog(@"[+] Bearer token authentication active.");
    
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    
    if (self.listenSource) {
        dispatch_source_cancel(self.listenSource);
        self.listenSource = nil;
    }
    if (self.serverFd >= 0) {
        close(self.serverFd);
        self.serverFd = -1;
    }
    self.isRunning = NO;
    NSLog(@"[+] Relay HTTP listener stopped.");
}

- (void)handleIncomingConnection {
    struct sockaddr_in clientAddr;
    socklen_t clientLen = sizeof(clientAddr);
    int clientFd = accept(self.serverFd, (struct sockaddr *)&clientAddr, &clientLen);
    if (clientFd < 0) return;
    
    int nosigpipe = 1;
    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    
    char clientIP[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &clientAddr.sin_addr, clientIP, sizeof(clientIP));
    NSString *clientIPStr = [NSString stringWithUTF8String:clientIP];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableData *requestData = [NSMutableData data];
        char buf[8192];
        ssize_t n;
        NSInteger contentLength = -1;
        NSUInteger headerEndIndex = NSNotFound;
        
        while ((n = read(clientFd, buf, sizeof(buf))) > 0) {
            [requestData appendBytes:buf length:n];
            
            // Check if headers have been fully read
            if (headerEndIndex == NSNotFound) {
                const char *bytes = (const char *)requestData.bytes;
                NSUInteger len = requestData.length;
                for (NSUInteger i = 0; i + 3 < len; i++) {
                    if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                        headerEndIndex = i + 4;
                        NSString *headersString = [[NSString alloc] initWithBytes:bytes length:i encoding:NSUTF8StringEncoding];
                        if (headersString) {
                            NSArray *hlines = [headersString componentsSeparatedByString:@"\r\n"];
                            for (NSString *line in hlines) {
                                if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                                    NSString *lenStr = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                    contentLength = [lenStr integerValue];
                                    break;
                                }
                            }
                        }
                        break;
                    }
                }
            }
            
            if (headerEndIndex != NSNotFound) {
                if (contentLength <= 0) break;
                if ((NSInteger)(requestData.length - headerEndIndex) >= contentLength) break;
            }
        }
        
        if (requestData.length == 0 || headerEndIndex == NSNotFound) {
            close(clientFd);
            return;
        }
        
        NSString *headerSection = [[NSString alloc] initWithBytes:requestData.bytes length:headerEndIndex encoding:NSUTF8StringEncoding];
        if (!headerSection) {
            close(clientFd);
            return;
        }
        
        NSArray *lines = [headerSection componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) {
            close(clientFd);
            return;
        }
        
        NSArray *reqParts = [lines[0] componentsSeparatedByString:@" "];
        if (reqParts.count < 2) {
            close(clientFd);
            return;
        }
        
        NSString *method = reqParts[0];
        NSString *uri = reqParts[1];
        
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        for (NSUInteger i = 1; i < lines.count; i++) {
            NSString *line = lines[i];
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                NSString *k = [[line substringToIndex:colon.location] lowercaseString];
                NSString *v = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                headers[k] = v;
            }
        }
        
        NSString *body = @"";
        if (requestData.length > headerEndIndex) {
            body = [[NSString alloc] initWithBytes:((const char *)requestData.bytes + headerEndIndex)
                                            length:(requestData.length - headerEndIndex)
                                          encoding:NSUTF8StringEncoding] ?: @"";
        }
        
        // Handle OPTIONS (CORS preflight)
        if ([method isEqualToString:@"OPTIONS"]) {
            NSString *corsResponse = @"HTTP/1.1 204 No Content\r\n"
                                     "Access-Control-Allow-Origin: *\r\n"
                                     "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                                     "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
                                     "Connection: close\r\n\r\n";
            write(clientFd, [corsResponse UTF8String], corsResponse.length);
            close(clientFd);
            return;
        }
        
        // Bearer Token Authentication Check
        NSString *authHeader = headers[@"authorization"];
        BOOL authorized = NO;
        if (authHeader) {
            NSString *trimmedAuth = [authHeader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmedAuth hasPrefix:@"Bearer "] || [trimmedAuth hasPrefix:@"bearer "]) {
                NSString *token = [[trimmedAuth substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([token isEqualToString:self.bearerToken]) {
                    authorized = YES;
                }
            }
        }
        
        if (!authorized) {
            NSLog(@"[SECURITY] Unauthorized request from %@ to %@ %@ - Missing or invalid Bearer token", clientIPStr, method, uri);
            [self sendUnauthorizedResponse:clientFd];
            return;
        }
        
        // Dispatch authorized request to main queue (IMCore requirement)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self routeMethod:method uri:uri body:body clientFd:clientFd];
        });
    });
}

- (void)sendUnauthorizedResponse:(int)clientFd {
    NSDictionary *err = @{
        @"error": @"Unauthorized",
        @"message": @"Valid Authorization: Bearer <TOKEN> header required"
    };
    [self sendJSONResponse:err statusCode:401 clientFd:clientFd];
}

- (void)routeMethod:(NSString *)method uri:(NSString *)uri body:(NSString *)body clientFd:(int)clientFd {
    @try {
        NSString *path = [NSURL URLWithString:uri] ? [[NSURL URLWithString:uri] path] : uri;
        if ([path hasSuffix:@"/"] && path.length > 1) {
            path = [path substringToIndex:path.length - 1];
        }
        
        NSLog(@"[+] Inbound HTTP: %@ %@ (body length: %lu bytes)", method, path, (unsigned long)body.length);
        
        if ([method isEqualToString:@"POST"] && ([path isEqualToString:@"/send"] || [path isEqualToString:@"/api/send"])) {
            [self handleSendRequestWithBody:body clientFd:clientFd];
        } else if ([method isEqualToString:@"POST"] && ([path isEqualToString:@"/react"] || [path isEqualToString:@"/api/react"])) {
            [self handleReactRequestWithBody:body clientFd:clientFd];
        } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/test-webhook"]) {
            [self handleTestWebhookRequestWithBody:body clientFd:clientFd];
        } else if ([method isEqualToString:@"POST"] && ([path isEqualToString:@"/retry-webhook"] || [path isEqualToString:@"/api/retry-webhook"])) {
            [self handleRetryWebhookRequest:clientFd];
        } else if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/status"] || [path isEqualToString:@"/"])) {
            [self handleStatusRequest:clientFd];
        } else if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/help"] || [path isEqualToString:@"/info"])) {
            [self sendJSONResponse:@{
                @"service": @"crapple-relay-12",
                @"version": @"macOS 12.7.6 (Monterey)",
                @"relay_version": [HTTPServer formattedRelayVersion],
                @"commit": [HTTPServer relayGitCommit],
                @"status": @"online",
                @"endpoints": @[@"GET /status", @"GET /chats", @"GET /accounts", @"GET /help", @"GET /info", @"POST /send", @"POST /react", @"POST /retry-webhook", @"POST /test-webhook"],
                @"spec_file": @"~/gateway.txt"
            } statusCode:200 clientFd:clientFd];
        } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/chats"]) {
            [self handleChatsRequest:clientFd];
        } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/accounts"]) {
            [self handleAccountsRequest:clientFd];
        } else {
            [self sendJSONResponse:@{@"error": @"Not Found", @"path": path} statusCode:404 clientFd:clientFd];
        }
    } @catch (NSException *e) {
        NSLog(@"[FATAL ERROR] Exception caught in routeMethod: %@ (reason: %@)", e.name, e.reason);
        [self sendJSONResponse:@{@"error": @"Internal Server Error", @"reason": e.reason ?: @""} statusCode:500 clientFd:clientFd];
    }
}

#pragma mark - Outbound Send Handler

- (void)handleSendRequestWithBody:(NSString *)body clientFd:(int)clientFd {
    NSLog(@"[+] Processing /send payload: %@", body);
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!bodyData || bodyData.length == 0) {
        NSLog(@"[ERROR] /send 400 Bad Request: Empty or invalid body");
        [self sendJSONResponse:@{@"error": @"Empty or invalid body"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ERROR] /send 400 Bad Request: Invalid JSON payload (%@)", jsonError.localizedDescription);
        [self sendJSONResponse:@{@"error": @"Invalid JSON payload", @"details": jsonError.localizedDescription ?: @""} statusCode:400 clientFd:clientFd];
        return;
    }
    
    NSString *recipient = json[@"recipient"] ?: json[@"to"] ?: json[@"sender"] ?: json[@"target"] ?: json[@"destination"];
    NSString *chatGUID = json[@"chat_guid"] ?: json[@"chat_identifier"];
    
    NSString *text = json[@"text"] ?: json[@"body"] ?: json[@"message"] ?: json[@"content"];
    NSString *subject = json[@"subject"];
    NSString *threadIdentifier = json[@"thread_id"];
    
    NSString *filename = json[@"filename"] ?: json[@"attachment_name"] ?: json[@"file_name"] ?: json[@"name"];
    NSString *mimeType = json[@"mime_type"] ?: json[@"attachment_mime"] ?: json[@"content_type"];
    NSString *base64Data = json[@"base64_data"] ?: json[@"attachment_base64"] ?: json[@"attachment"] ?: json[@"data"];
    
    BOOL hasText = (text != nil && text.length > 0);
    BOOL hasAttachment = (base64Data != nil && base64Data.length > 0);
    
    if (!hasText && !hasAttachment) {
        NSLog(@"[ERROR] /send 400 Bad Request: Payload missing both text and attachment");
        [self sendJSONResponse:@{@"error": @"Payload must contain either 'text'/'body'/'message' or attachment 'base64_data'"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    if ((!recipient || recipient.length == 0) && (!chatGUID || chatGUID.length == 0)) {
        NSLog(@"[ERROR] /send 400 Bad Request: Missing recipient/to/sender and chat_guid");
        [self sendJSONResponse:@{@"error": @"Must provide either 'recipient' (or 'to'/'sender') or 'chat_guid'"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    IMServiceManager *mgr = [IMServiceManager sharedInstance];
    if (![mgr isConnected]) {
        [self sendJSONResponse:@{@"error": @"IMDaemonController is not connected to imagent"} statusCode:503 clientFd:clientFd];
        return;
    }
    
    IMChat *chat = [mgr resolveChatForRecipient:recipient chatGUID:chatGUID];
    if (!chat) {
        [self sendJSONResponse:@{@"error": @"Failed to resolve or create IMChat target"} statusCode:500 clientFd:clientFd];
        return;
    }
    
    NSString *transferGUID = nil;
    NSString *cleanFilename = nil;
    NSData *decodedAttachmentData = nil;
    
    if (hasAttachment) {
        decodedAttachmentData = [[NSData alloc] initWithBase64EncodedString:base64Data
                                                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!decodedAttachmentData || decodedAttachmentData.length == 0) {
            [self sendJSONResponse:@{@"error": @"Failed to decode base64_data payload"} statusCode:400 clientFd:clientFd];
            return;
        }
        
        NSError *transferError = nil;
        transferGUID = [mgr registerFileTransferWithData:decodedAttachmentData
                                                filename:filename
                                                mimeType:mimeType
                                           savedFilename:&cleanFilename
                                                   error:&transferError];
        if (!transferGUID) {
            NSLog(@"[ERROR] registerFileTransfer failed: %@", transferError);
            [self sendJSONResponse:@{@"error": transferError.localizedDescription ?: @"Failed to register file transfer"} statusCode:500 clientFd:clientFd];
            return;
        }
        NSLog(@"[+] Registered file transfer GUID: %@ (%lu bytes, filename: %@)", transferGUID, (unsigned long)decodedAttachmentData.length, cleanFilename);
    }
    
    NSError *sendError = nil;
    IMMessage *message = [mgr sendMessageToChat:chat
                                           text:text
                                        subject:subject
                                   transferGUID:transferGUID
                                  cleanFilename:cleanFilename
                                       threadID:threadIdentifier
                                          error:&sendError];
    if (!message) {
        [self sendJSONResponse:@{@"error": sendError.localizedDescription ?: @"Failed to instantiate IMMessage"} statusCode:500 clientFd:clientFd];
        return;
    }
    
    NSLog(@"[+] Dispatching IMMessage (GUID: %@) with %lu attachments to chat '%@'", message.guid, (unsigned long)(transferGUID ? 1 : 0), chat.chatIdentifier ?: chat.guid);
    
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:@{
        @"status": @"success",
        @"message_guid": message.guid ?: [NSNull null],
        @"chat_identifier": chat.chatIdentifier ?: [NSNull null],
        @"chat_guid": chat.guid ?: [NSNull null],
        @"recipient": recipient ?: (chat.recipient.ID ?: [NSNull null]),
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    }];
    
    if (transferGUID) {
        response[@"transfer_guid"] = transferGUID;
        response[@"filename"] = cleanFilename ?: [NSNull null];
        response[@"mime_type"] = mimeType ?: [NSNull null];
        response[@"file_size"] = @(decodedAttachmentData.length);
    }
    
    [self sendJSONResponse:response statusCode:200 clientFd:clientFd];
}

#pragma mark - Tapback Reaction Handler

- (void)handleReactRequestWithBody:(NSString *)body clientFd:(int)clientFd {
    NSLog(@"[+] Processing /react payload: %@", body);
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!bodyData || bodyData.length == 0) {
        NSLog(@"[ERROR] /react 400 Bad Request: Empty or invalid body");
        [self sendJSONResponse:@{@"error": @"Empty or invalid body"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ERROR] /react 400 Bad Request: Invalid JSON payload (%@)", jsonError.localizedDescription);
        [self sendJSONResponse:@{@"error": @"Invalid JSON payload", @"details": jsonError.localizedDescription ?: @""} statusCode:400 clientFd:clientFd];
        return;
    }
    
    NSString *recipient = json[@"recipient"] ?: json[@"to"] ?: json[@"sender"] ?: json[@"target"] ?: json[@"destination"];
    NSString *chatGUID = json[@"chat_guid"] ?: json[@"chat_identifier"];
    NSString *targetGUID = json[@"original_message_guid"] ?: json[@"message_guid"] ?: json[@"guid"] ?: json[@"associated_message_guid"];
    id tapbackVal = json[@"tapback_type"] ?: json[@"type"] ?: json[@"reaction"] ?: json[@"acknowledgment_type"];
    
    BOOL explicitRemoval = [json[@"remove"] boolValue] || [json[@"is_removal"] boolValue] || [[json[@"action"] lowercaseString] isEqualToString:@"remove"];
    
    if (!targetGUID || targetGUID.length == 0) {
        NSLog(@"[ERROR] /react 400 Bad Request: Missing 'original_message_guid'");
        [self sendJSONResponse:@{@"error": @"Missing required field 'original_message_guid' (or 'message_guid')"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    if (!tapbackVal) {
        NSLog(@"[ERROR] /react 400 Bad Request: Missing 'tapback_type'");
        [self sendJSONResponse:@{@"error": @"Missing required field 'tapback_type'"} statusCode:400 clientFd:clientFd];
        return;
    }
    
    BOOL parsedRemoval = NO;
    int64_t tapbackType = [IMServiceManager parseTapbackType:tapbackVal isRemoval:&parsedRemoval];
    if (explicitRemoval && tapbackType >= 2000 && tapbackType <= 2005) {
        tapbackType += 1000;
        parsedRemoval = YES;
    }
    
    if (tapbackType < 2000 || (tapbackType > 2005 && tapbackType < 3000) || tapbackType > 3005) {
        NSLog(@"[ERROR] /react 400 Bad Request: Invalid tapback_type '%@'", tapbackVal);
        [self sendJSONResponse:@{
            @"error": @"Invalid 'tapback_type'",
            @"supported_types": @[@"Love", @"Like", @"Dislike", @"Laugh", @"Emphasize", @"Question"],
            @"details": [NSString stringWithFormat:@"Could not map '%@' to a valid tapback code", tapbackVal]
        } statusCode:400 clientFd:clientFd];
        return;
    }
    
    IMServiceManager *mgr = [IMServiceManager sharedInstance];
    if (![mgr isConnected]) {
        [self sendJSONResponse:@{@"error": @"IMDaemonController is not connected to imagent"} statusCode:503 clientFd:clientFd];
        return;
    }
    
    // Normalize target GUID and associatedMessageGUID
    NSString *rawGUID = targetGUID;
    if ([rawGUID hasPrefix:@"p:"] || [rawGUID hasPrefix:@"bp:"]) {
        NSRange slashRange = [rawGUID rangeOfString:@"/"];
        if (slashRange.location != NSNotFound) {
            rawGUID = [rawGUID substringFromIndex:slashRange.location + 1];
        }
    }
    
    NSString *associatedGUID = ([targetGUID hasPrefix:@"p:"] || [targetGUID hasPrefix:@"bp:"]) ?
                               targetGUID : [NSString stringWithFormat:@"p:0/%@", targetGUID];
    
    // Look up original message info in chat.db if recipient/chat or text is needed
    NSString *discoveredRecipient = nil;
    NSString *discoveredChatGUID = nil;
    NSString *originalText = nil;
    
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) == SQLITE_OK) {
        const char *query = "SELECT c.chat_identifier, c.guid, m.text "
                            "FROM message m "
                            "LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id "
                            "LEFT JOIN chat c ON cmj.chat_id = c.ROWID "
                            "WHERE m.guid = ? LIMIT 1";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [rawGUID UTF8String], -1, SQLITE_STATIC);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                const char *cIdent = (const char *)sqlite3_column_text(stmt, 0);
                if (cIdent) discoveredRecipient = [NSString stringWithUTF8String:cIdent];
                const char *cGUID = (const char *)sqlite3_column_text(stmt, 1);
                if (cGUID) discoveredChatGUID = [NSString stringWithUTF8String:cGUID];
                const char *txt = (const char *)sqlite3_column_text(stmt, 2);
                if (txt) {
                    originalText = [NSString stringWithUTF8String:txt];
                    originalText = [originalText stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
                    originalText = [originalText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            }
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db);
    }
    
    if ((!recipient || recipient.length == 0) && discoveredRecipient) {
        recipient = discoveredRecipient;
    }
    if ((!chatGUID || chatGUID.length == 0) && discoveredChatGUID) {
        chatGUID = discoveredChatGUID;
    }
    
    IMChat *chat = [mgr resolveChatForRecipient:recipient chatGUID:chatGUID];
    if (!chat) {
        [self sendJSONResponse:@{
            @"error": @"Failed to resolve or create IMChat target",
            @"recipient": recipient ?: [NSNull null],
            @"chat_guid": chatGUID ?: [NSNull null]
        } statusCode:404 clientFd:clientFd];
        return;
    }
    
    // Generate backward compatibility summary text
    NSString *compatString = [IMServiceManager backwardCompatibilityStringForType:tapbackType originalText:originalText];
    
    NSError *reactError = nil;
    IMMessage *reactMsg = [mgr sendTapbackToChat:chat
                                  associatedGUID:associatedGUID
                                     tapbackType:tapbackType
                                    compatString:compatString
                                           error:&reactError];
    if (!reactMsg) {
        [self sendJSONResponse:@{@"error": reactError.localizedDescription ?: @"Failed to instantiate associated IMMessage"} statusCode:500 clientFd:clientFd];
        return;
    }
    
    NSLog(@"[+] Dispatching reaction '%@' (code %lld, GUID: %@) -> associated '%@' in chat '%@'",
          [IMServiceManager nameForTapbackType:tapbackType], (long long)tapbackType, reactMsg.guid, associatedGUID, chat.chatIdentifier ?: chat.guid);
    
    NSDictionary *response = @{
        @"status": @"success",
        @"message_guid": reactMsg.guid ?: [NSNull null],
        @"original_message_guid": rawGUID,
        @"associated_message_guid": associatedGUID,
        @"tapback_type": [IMServiceManager nameForTapbackType:tapbackType],
        @"tapback_code": @(tapbackType),
        @"is_removal": @(tapbackType >= 3000),
        @"recipient": recipient ?: (chat.recipient.ID ?: chat.chatIdentifier ?: [NSNull null]),
        @"chat_identifier": chat.chatIdentifier ?: [NSNull null],
        @"chat_guid": chat.guid ?: [NSNull null],
        @"backward_compatibility_text": compatString ?: @"",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    
    [self sendJSONResponse:response statusCode:200 clientFd:clientFd];
}

#pragma mark - Diagnostics and Status Handlers

- (void)handleStatusRequest:(int)clientFd {
    IMServiceManager *mgr = [IMServiceManager sharedInstance];
    MessageObserver *obs = [MessageObserver sharedInstance];
    IMDaemonController *dc = [IMDaemonController sharedController];
    IMAccount *activeIMessage = [mgr bestSendingAccount];
    
    NSString *commitStr = [HTTPServer relayGitCommit];
    
    NSDictionary *status = @{
        @"status": @"online",
        @"daemon_name": @"crapple-relay-12",
        @"version": @"macOS 12.7.6 (Monterey)",
        @"relay_version": [HTTPServer formattedRelayVersion],
        @"commit": commitStr,
        @"git_commit": commitStr,
        @"os_version": @"macOS 12.7.6 (Monterey)",
        @"security": @{
            @"bound_host": self.host,
            @"incoming_port": @(self.port),
            @"auth_type": @"Bearer Token"
        },
        @"outgoing_webhook": @{
            @"url": obs.webhookURL ?: @"",
            @"default_port": @(5569),
            @"auth_configured": @(obs.webhookToken.length > 0)
        },
        @"incoming_observer_active": @(obs.isRunning),
        @"daemon_connected": @([dc isConnected]),
        @"listener_id": [dc _listenerID] ?: @"",
        @"imessage_account": activeIMessage ? @{
            @"login": activeIMessage.login ?: @"",
            @"service": activeIMessage.serviceName ?: @"",
            @"connected": @(activeIMessage.isConnected),
            @"uniqueID": activeIMessage.uniqueID ?: @""
        } : [NSNull null],
        @"active_accounts_count": @([mgr activeAccountsCount]),
        @"total_chats": @([mgr totalChatsCount]),
        @"accounts": [mgr accountsInfoList]
    };
    
    [self sendJSONResponse:status statusCode:200 clientFd:clientFd];
}

- (void)handleChatsRequest:(int)clientFd {
    @try {
        NSArray *chatList = [[IMServiceManager sharedInstance] allChatsInfoList];
        [self sendJSONResponse:@{@"chats": chatList, @"count": @(chatList.count)} statusCode:200 clientFd:clientFd];
    } @catch (NSException *ex) {
        NSLog(@"[ERROR] Exception in handleChatsRequest: %@", ex);
        [self sendJSONResponse:@{@"error": @"Failed to query chats", @"reason": ex.reason ?: @""} statusCode:500 clientFd:clientFd];
    }
}

- (void)handleAccountsRequest:(int)clientFd {
    NSArray *accounts = [[IMServiceManager sharedInstance] accountsInfoList];
    [self sendJSONResponse:@{@"accounts": accounts, @"count": @(accounts.count)} statusCode:200 clientFd:clientFd];
}

- (void)handleTestWebhookRequestWithBody:(NSString *)body clientFd:(int)clientFd {
    NSDictionary *payload = nil;
    if (body && body.length > 0) {
        NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
        if (data) {
            payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
    }
    if (!payload || ![payload isKindOfClass:[NSDictionary class]]) {
        payload = @{
            @"sender": @"+15551234567",
            @"message": @"Test incoming message via /test-webhook",
            @"attachment_base64": @"",
            @"attachment_mime": @"",
            @"attachment_name": @""
        };
    }
    
    MessageObserver *obs = [MessageObserver sharedInstance];
    [obs dispatchWebhookWithPayload:payload];
    
    [self sendJSONResponse:@{
        @"status": @"dispatched",
        @"webhook_url": obs.webhookURL ?: @"",
        @"payload": payload
    } statusCode:200 clientFd:clientFd];
}

- (void)handleRetryWebhookRequest:(int)clientFd {
    NSError *error = nil;
    NSDictionary *result = [[MessageObserver sharedInstance] retryLastIncomingMessageWithError:&error];
    if (result) {
        [self sendJSONResponse:result statusCode:200 clientFd:clientFd];
    } else {
        [self sendJSONResponse:@{@"error": error.localizedDescription ?: @"Failed to retry incoming message"} statusCode:404 clientFd:clientFd];
    }
}

#pragma mark - HTTP Utilities

- (void)sendJSONResponse:(id)obj statusCode:(int)statusCode clientFd:(int)clientFd {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted error:&err];
    if (err || !data) {
        data = [@"{\"error\":\"Internal Serialization Error\"}\n" dataUsingEncoding:NSUTF8StringEncoding];
        statusCode = 500;
    }
    
    NSString *statusText = (statusCode == 200) ? @"OK" :
                           (statusCode == 400) ? @"Bad Request" :
                           (statusCode == 401) ? @"Unauthorized" :
                           (statusCode == 404) ? @"Not Found" :
                           (statusCode == 503) ? @"Service Unavailable" : @"Internal Server Error";
    
    NSString *authHeaderLine = (statusCode == 401) ? @"WWW-Authenticate: Bearer realm=\"Crapple Relay\"\r\n" : @"";
    
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %d %@\r\n"
                        "%@"
                        "Content-Type: application/json; charset=utf-8\r\n"
                        "Content-Length: %lu\r\n"
                        "Access-Control-Allow-Origin: *\r\n"
                        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
                        "Connection: close\r\n"
                        "\r\n",
                        statusCode, statusText, authHeaderLine, (unsigned long)data.length];
    
    NSMutableData *resp = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [resp appendData:data];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        write(clientFd, resp.bytes, resp.length);
        close(clientFd);
    });
}

@end
