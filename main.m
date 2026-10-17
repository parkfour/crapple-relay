#import <Foundation/Foundation.h>
#import "Headers/IMCoreBridge.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <signal.h>
#import <sys/stat.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <syslog.h>
#import <os/log.h>

static os_log_t g_relay_log = NULL;

static void RelayLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!msg) return;
    
    const char *utf8 = [msg UTF8String];
    
    // 1. Apple Unified Logging (os_log) - Subsystem com.crapple.imessage-relay
    if (!g_relay_log) {
        g_relay_log = os_log_create("com.crapple.imessage-relay", "daemon");
    }
    os_log_with_type(g_relay_log, OS_LOG_TYPE_DEFAULT, "%{public}s", utf8);
    
    // 2. POSIX syslog
    syslog(LOG_NOTICE, "%s", utf8);
    
    // 3. Output to stderr if connected to an interactive terminal
    if (isatty(STDERR_FILENO)) {
        fprintf(stderr, "%s\n", utf8);
    }
}

#undef NSLog
#define NSLog(fmt, ...) RelayLog((fmt), ##__VA_ARGS__)

// Security & Network Configuration
static const int kDefaultPort = 5569;
static NSString * const kDefaultWebhookURL = @"http://127.0.0.1:5569/receive-imessage";

@interface RelayServer : NSObject
@property (nonatomic, assign) int serverFd;
@property (nonatomic, strong) dispatch_source_t listenSource;
@property (nonatomic, strong) NSString *host;
@property (nonatomic, assign) int port;
@property (nonatomic, strong) NSString *bearerToken;
@property (nonatomic, strong) NSString *webhookURL;
@property (nonatomic, strong) NSString *webhookToken;
@property (nonatomic, strong) NSMutableSet<NSString *> *processedMessageGUIDs;
@property (nonatomic, assign) int64_t lastProcessedRowID;
@property (nonatomic, strong) dispatch_source_t dbPollTimer;

+ (NSString *)resolveDefaultIP;
- (instancetype)initWithHost:(NSString *)host 
                        port:(int)port 
                 bearerToken:(NSString *)token 
                  webhookURL:(NSString *)webhookURL 
                webhookToken:(NSString *)webhookToken;
- (BOOL)start;
- (void)stop;
- (void)processIncomingMessage:(IMMessage *)message chat:(nullable IMChat *)chat;
- (void)dispatchWebhookWithPayload:(NSDictionary *)payload;
- (void)checkDatabaseForNewMessages;
- (void)retryLastIncomingMessage:(int)clientFd;
+ (int64_t)parseTapbackType:(id)tapbackVal isRemoval:(BOOL *)isRemovalOut;
+ (NSString *)nameForTapbackType:(int64_t)type;
- (void)handleReactRequestWithBody:(NSString *)body clientFd:(int)clientFd;
@end

static RelayServer *g_server = nil;

@implementation RelayServer

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
                
                // Prioritize private mesh interfaces (e.g. Tailscale 100.x or private 10.x overlay subnets)
                if ([ipStr hasPrefix:@"100."] || [ipStr hasPrefix:@"10."]) {
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

- (instancetype)initWithHost:(NSString *)host 
                        port:(int)port 
                 bearerToken:(NSString *)token 
                  webhookURL:(NSString *)webhookURL 
                webhookToken:(NSString *)webhookToken {
    self = [super init];
    if (self) {
        _host = (host && host.length > 0) ? host : [RelayServer resolveDefaultIP];
        _port = port > 0 ? port : kDefaultPort;
        _bearerToken = (token && token.length > 0) ? token : [[NSUUID UUID] UUIDString];
        _webhookURL = (webhookURL && webhookURL.length > 0) ? webhookURL : kDefaultWebhookURL;
        _webhookToken = (webhookToken && webhookToken.length > 0) ? webhookToken : _bearerToken;
        _processedMessageGUIDs = [NSMutableSet set];
        _serverFd = -1;
    }
    return self;
}

- (BOOL)start {
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
        NSLog(@"[ERROR] Invalid Nebula IP address format: %@", self.host);
        close(fd);
        return NO;
    }
    
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[ERROR] Failed to bind strictly to Nebula interface %@:%d: %s", self.host, self.port, strerror(errno));
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
    NSLog(@"[+] Relay HTTP listener securely bound strictly to Nebula IP http://%@:%d", self.host, self.port);
    NSLog(@"[+] Bearer token authentication active.");
    
    // Register notification observers for incoming messages
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"__kIMChatRegistryMessageReceivedNotification" object:nil];
    [nc addObserver:self selector:@selector(handleMessageNotification:) name:@"IMChatRegistryMessageReceivedNotification" object:nil];
    
    NSLog(@"[+] Real-time incoming IMCore message observer registered.");
    
    // Initialize chat.db SQLite watcher
    [self checkDatabaseForNewMessages];
    
    // Schedule periodic chat.db polling timer (every 1.0 second)
    self.dbPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(self.dbPollTimer, dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), 1000 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.dbPollTimer, ^{
        [weakSelf checkDatabaseForNewMessages];
    });
    dispatch_resume(self.dbPollTimer);
    NSLog(@"[+] Real-time chat.db SQLite observer active (polling interval: 1.0s).");
    
    NSLog(@"[+] Outgoing webhook configured for %@ (port 5569).", self.webhookURL);
    
    return YES;
}

- (void)stop {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.dbPollTimer) {
        dispatch_source_cancel(self.dbPollTimer);
        self.dbPollTimer = nil;
    }
    if (self.listenSource) {
        dispatch_source_cancel(self.listenSource);
        self.listenSource = nil;
    }
    if (self.serverFd >= 0) {
        close(self.serverFd);
        self.serverFd = -1;
    }
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
                if (contentLength >= 0) {
                    NSInteger currentBodyLength = (NSInteger)requestData.length - (NSInteger)headerEndIndex;
                    if (currentBodyLength >= contentLength) {
                        break;
                    }
                } else {
                    break;
                }
            }
        }
        
        if (requestData.length == 0) {
            close(clientFd);
            return;
        }
        
        NSString *requestStr = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        if (!requestStr) {
            close(clientFd);
            return;
        }
        
        // Parse request line and headers
        NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) {
            close(clientFd);
            return;
        }
        
        NSArray *requestTokens = [lines[0] componentsSeparatedByString:@" "];
        if (requestTokens.count < 2) {
            close(clientFd);
            return;
        }
        
        NSString *method = requestTokens[0];
        NSString *uri = requestTokens[1];
        
        // Parse headers into lowercase key dictionary
        NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
        NSRange bodySepRange = [requestStr rangeOfString:@"\r\n\r\n"];
        NSString *headerPart = (bodySepRange.location != NSNotFound) ? [requestStr substringToIndex:bodySepRange.location] : requestStr;
        NSString *body = (bodySepRange.location != NSNotFound) ? [requestStr substringFromIndex:bodySepRange.location + 4] : @"";
        
        NSArray *headerLines = [headerPart componentsSeparatedByString:@"\r\n"];
        for (NSUInteger i = 1; i < headerLines.count; i++) {
            NSString *line = headerLines[i];
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
                NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                headers[key] = val;
            }
        }
        
        // Handle CORS Preflight (OPTIONS)
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
        
        // Security Constraint 2 & 3: Bearer Token Authentication Check
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
            [self retryLastIncomingMessage:clientFd];
        } else if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/status"] || [path isEqualToString:@"/"])) {
            [self handleStatusRequest:clientFd];
        } else if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/help"] || [path isEqualToString:@"/info"])) {
            [self sendJSONResponse:@{
                @"service": @"crapple-relay-12",
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

#pragma mark - Incoming Message Observer & Webhook Dispatcher

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
    
    if (msg) {
        [self processIncomingMessage:msg chat:chat];
    }
}

- (void)processIncomingMessage:(IMMessage *)message chat:(nullable IMChat *)chat {
    if (!message || ![message isKindOfClass:[IMMessage class]]) return;
    
    // Filter Outgoing: Ensure the observer ignores messages sent by the user, only capturing messages sent to the user
    if (message.isFromMe) {
        return;
    }
    
    NSString *guid = message.guid;
    if (guid.length > 0) {
        if ([self.processedMessageGUIDs containsObject:guid]) {
            return;
        }
        [self.processedMessageGUIDs addObject:guid];
        if (self.processedMessageGUIDs.count > 2000) {
            [self.processedMessageGUIDs removeAllObjects];
        }
    }
    
    // 1. Sender (phone number or email)
    NSString *sender = message.sender.ID ?: message.sender.normalizedID ?: message.sender.displayID ?: @"";
    if (sender.length == 0 && chat && chat.recipient) {
        sender = chat.recipient.ID ?: chat.recipient.normalizedID ?: @"";
    }
    if (sender.length == 0 && chat && chat.chatIdentifier) {
        sender = chat.chatIdentifier;
    }
    
    // 2. Message text body (empty string if only media)
    NSString *body = message.plainBody ?: message.text.string ?: @"";
    body = [body stringByReplacingOccurrencesOfString:@"\uFFFC" withString:@""];
    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // 3. Media Attachments
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
    
    NSDictionary *payload = @{
        @"sender": sender ?: @"",
        @"message": body ?: @"",
        @"attachment_base64": attachmentBase64 ?: @"",
        @"attachment_mime": attachmentMime ?: @"",
        @"attachment_name": attachmentName ?: @""
    };
    
    NSLog(@"[+] Captured incoming iMessage from '%@': '%@' (media: %@, %lu bytes base64)",
          sender, body, attachmentName.length > 0 ? attachmentName : @"none", (unsigned long)attachmentBase64.length);
    
    [self dispatchWebhookWithPayload:payload];
}

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
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.webhookToken] forHTTPHeaderField:@"Authorization"];
    [req setValue:[NSString stringWithFormat:@"%lu", (unsigned long)bodyData.length] forHTTPHeaderField:@"Content-Length"];
    [req setHTTPBody:bodyData];
    [req setTimeoutInterval:10.0];
    
    NSLog(@"[+] Dispatching webhook POST to %@ for sender '%@'...", self.webhookURL, payload[@"sender"]);
    
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
    
    [self dispatchWebhookWithPayload:payload];
    
    [self sendJSONResponse:@{
        @"status": @"dispatched",
        @"webhook_url": self.webhookURL,
        @"payload": payload
    } statusCode:200 clientFd:clientFd];
}

- (void)checkDatabaseForNewMessages {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return;
    
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    
    // Initial bootstrap: if lastProcessedRowID is 0, find current max ROWID
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
                        "       att.filename, att.mime_type, att.transfer_name "
                        "FROM message m "
                        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
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
            
            const char *senderC = (const char *)sqlite3_column_text(stmt, 3);
            NSString *sender = senderC ? [NSString stringWithUTF8String:senderC] : @"";
            
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
            
            NSDictionary *payload = @{
                @"sender": sender ?: @"",
                @"message": text ?: @"",
                @"attachment_base64": attachmentBase64 ?: @"",
                @"attachment_mime": attachmentMime ?: @"",
                @"attachment_name": attachmentName ?: @""
            };
            
            NSLog(@"[+] [chat.db] Captured incoming iMessage (ROWID %lld, GUID %@) from '%@': '%@'",
                  rowID, guid, sender, text);
            [self dispatchWebhookWithPayload:payload];
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
}

- (void)retryLastIncomingMessage:(int)clientFd {
    NSString *dbPath = [@"~/Library/Messages/chat.db" stringByExpandingTildeInPath];
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", dbPath];
    if (sqlite3_open_v2([uri UTF8String], &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        if (clientFd >= 0) {
            [self sendJSONResponse:@{@"error": @"Unable to open chat.db"} statusCode:500 clientFd:clientFd];
        }
        return;
    }
    
    const char *query = "SELECT m.ROWID, m.guid, m.text, h.id, m.is_from_me, m.date, "
                        "       att.filename, att.mime_type, att.transfer_name "
                        "FROM message m "
                        "LEFT JOIN handle h ON m.handle_id = h.ROWID "
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
            
            const char *senderC = (const char *)sqlite3_column_text(stmt, 3);
            NSString *sender = senderC ? [NSString stringWithUTF8String:senderC] : @"";
            
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
            
            payload = @{
                @"sender": sender ?: @"",
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
        if (clientFd >= 0) {
            [self sendJSONResponse:@{
                @"status": @"retrying",
                @"rowid": @(rowID),
                @"guid": guid,
                @"payload": payload,
                @"webhook_url": self.webhookURL
            } statusCode:200 clientFd:clientFd];
        }
    } else {
        if (clientFd >= 0) {
            [self sendJSONResponse:@{@"error": @"No incoming messages found to retry"} statusCode:404 clientFd:clientFd];
        }
    }
}

#pragma mark - IMCore Actions

- (IMAccount *)getBestSendingAccount {
    IMAccountController *ac = [IMAccountController sharedInstance];
    
    for (IMAccount *acc in ac.activeAccounts) {
        if ([acc.serviceName isEqualToString:@"iMessage"] && acc.isConnected) {
            return acc;
        }
    }
    
    for (IMAccount *acc in ac.activeAccounts) {
        if ([acc.serviceName isEqualToString:@"iMessage"]) {
            return acc;
        }
    }
    
    IMAccount *imAccount = [ac activeIMessageAccount];
    if (imAccount) return imAccount;
    
    IMService *imService = [IMService iMessageService];
    if (imService) {
        IMAccount *operational = [ac bestOperationalAccountForService:imService];
        if (operational) return operational;
    }
    
    if (ac.activeAccounts.count > 0) {
        return ac.activeAccounts[0];
    }
    
    return nil;
}

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
    
    // Support "recipient", "to", "sender", "target", "destination"
    NSString *recipient = json[@"recipient"] ?: json[@"to"] ?: json[@"sender"] ?: json[@"target"] ?: json[@"destination"];
    NSString *chatGUID = json[@"chat_guid"] ?: json[@"chat_identifier"];
    
    // Support "text", "body", "message", "content"
    NSString *text = json[@"text"] ?: json[@"body"] ?: json[@"message"] ?: json[@"content"];
    NSString *subject = json[@"subject"];
    NSString *threadIdentifier = json[@"thread_id"];
    
    // Media attachment fields - support standard and webhook-mirror keys
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
    
    IMDaemonController *dc = [IMDaemonController sharedController];
    if (![dc isConnected]) {
        [self sendJSONResponse:@{@"error": @"IMDaemonController is not connected to imagent"} statusCode:503 clientFd:clientFd];
        return;
    }
    
    IMChatRegistry *registry = [IMChatRegistry sharedInstance];
    IMChat *chat = nil;
    
    if (chatGUID && chatGUID.length > 0) {
        chat = [registry existingChatWithGUID:chatGUID];
        if (!chat) {
            chat = [registry existingChatWithChatIdentifier:chatGUID];
        }
    }
    
    if (!chat && recipient && recipient.length > 0) {
        chat = [registry existingChatWithChatIdentifier:recipient];
        
        if (!chat) {
            IMAccount *account = [self getBestSendingAccount];
            if (!account) {
                [self sendJSONResponse:@{@"error": @"No active or operational iMessage/SMS account available"} statusCode:503 clientFd:clientFd];
                return;
            }
            
            IMHandle *handle = [account imHandleWithID:recipient];
            if (!handle) {
                [self sendJSONResponse:@{@"error": [NSString stringWithFormat:@"Failed to create IMHandle for '%@'", recipient]} statusCode:400 clientFd:clientFd];
                return;
            }
            
            chat = [registry chatForIMHandle:handle];
        }
    }
    
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
        
        if (filename && filename.length > 0) {
            cleanFilename = [filename lastPathComponent];
        }
        if (!cleanFilename || cleanFilename.length == 0) {
            NSString *ext = @"bin";
            if (mimeType) {
                if ([mimeType containsString:@"jpeg"] || [mimeType containsString:@"jpg"]) ext = @"jpg";
                else if ([mimeType containsString:@"png"]) ext = @"png";
                else if ([mimeType containsString:@"gif"]) ext = @"gif";
                else if ([mimeType containsString:@"pdf"]) ext = @"pdf";
                else if ([mimeType containsString:@"mp4"]) ext = @"mp4";
                else if ([mimeType containsString:@"quicktime"] || [mimeType containsString:@"mov"]) ext = @"mov";
                else if ([mimeType containsString:@"m4a"] || [mimeType containsString:@"aac"]) ext = @"m4a";
                else if ([mimeType containsString:@"mp3"]) ext = @"mp3";
            }
            cleanFilename = [NSString stringWithFormat:@"attachment.%@", ext];
        }
        
        NSString *uniqueFileName = [NSString stringWithFormat:@"%@_%@", [[NSUUID UUID] UUIDString], cleanFilename];
        NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:uniqueFileName];
        
        BOOL written = [decodedAttachmentData writeToFile:tempPath atomically:YES];
        if (!written) {
            NSLog(@"[ERROR] Failed to write attachment file to %@", tempPath);
            [self sendJSONResponse:@{@"error": @"Failed to write attachment to temporary disk storage"} statusCode:500 clientFd:clientFd];
            return;
        }
        
        chmod([tempPath UTF8String], 0644);
        
        NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
        IMFileTransferCenter *transferCenter = [IMFileTransferCenter sharedInstance];
        transferGUID = [transferCenter guidForNewOutgoingTransferWithLocalURL:fileURL];
        if (!transferGUID || transferGUID.length == 0) {
            NSLog(@"[ERROR] IMFileTransferCenter failed to generate transfer GUID for %@", fileURL);
            [self sendJSONResponse:@{@"error": @"Failed to register file transfer with IMFileTransferCenter"} statusCode:500 clientFd:clientFd];
            return;
        }
        
        IMFileTransfer *transfer = [transferCenter transferForGUID:transferGUID];
        if (cleanFilename && [transfer respondsToSelector:@selector(setFilename:)]) {
            [transfer setFilename:cleanFilename];
        }
        if (mimeType && [transfer respondsToSelector:@selector(setMimeType:)]) {
            [transfer setMimeType:mimeType];
        }
        
        [transferCenter registerTransferWithDaemon:transferGUID];
        NSLog(@"[+] Registered file transfer GUID: %@ (%lu bytes, filename: %@)", transferGUID, (unsigned long)decodedAttachmentData.length, cleanFilename);
    }
    
    NSMutableAttributedString *attrText = nil;
    NSArray<NSString *> *fileTransferGUIDs = nil;
    
    if (transferGUID) {
        unichar attachChar = 0xFFFC;
        NSString *attachStr = [NSString stringWithCharacters:&attachChar length:1];
        attrText = [[NSMutableAttributedString alloc] initWithString:attachStr];
        [attrText addAttribute:IMFileTransferGUIDAttributeName value:transferGUID range:NSMakeRange(0, 1)];
        if (cleanFilename) {
            [attrText addAttribute:IMFilenameAttributeName value:cleanFilename range:NSMakeRange(0, 1)];
        }
        
        if (hasText) {
            NSAttributedString *textPart = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", text]];
            [attrText appendAttributedString:textPart];
        }
        fileTransferGUIDs = @[transferGUID];
    } else {
        attrText = [[NSMutableAttributedString alloc] initWithString:text ?: @""];
    }
    
    NSAttributedString *attrSubject = subject ? [[NSAttributedString alloc] initWithString:subject] : nil;
    NSUInteger messageFlags = 0x5;
    
    IMMessage *message = nil;
    if (fileTransferGUIDs.count > 0) {
        message = [IMMessage instantMessageWithText:attrText
                                     messageSubject:attrSubject
                                  fileTransferGUIDs:fileTransferGUIDs
                                              flags:messageFlags
                                   threadIdentifier:threadIdentifier];
    } else {
        message = [IMMessage instantMessageWithText:attrText
                                     messageSubject:attrSubject
                                              flags:messageFlags
                                   threadIdentifier:threadIdentifier];
    }
    
    if (!message) {
        [self sendJSONResponse:@{@"error": @"Failed to instantiate IMMessage"} statusCode:500 clientFd:clientFd];
        return;
    }
    
    NSLog(@"[+] Dispatching IMMessage (GUID: %@) with %lu attachments to chat '%@'", message.guid, (unsigned long)fileTransferGUIDs.count, chat.chatIdentifier ?: chat.guid);
    [chat sendMessage:message];
    
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

+ (int64_t)parseTapbackType:(id)tapbackVal isRemoval:(BOOL *)isRemovalOut {
    if (isRemovalOut) *isRemovalOut = NO;
    if (!tapbackVal) return 0;
    
    if ([tapbackVal isKindOfClass:[NSNumber class]]) {
        long long val = [tapbackVal longLongValue];
        if (val >= 2000 && val <= 2005) {
            return val;
        }
        if (val >= 3000 && val <= 3005) {
            if (isRemovalOut) *isRemovalOut = YES;
            return val;
        }
        if (val >= 0 && val <= 5) {
            return 2000 + val;
        }
        return 0;
    }
    
    if (![tapbackVal isKindOfClass:[NSString class]]) return 0;
    
    NSString *clean = [[(NSString *)tapbackVal stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    long long intVal = 0;
    if ([scanner scanLongLong:&intVal] && [scanner isAtEnd]) {
        if (intVal >= 2000 && intVal <= 2005) {
            return intVal;
        }
        if (intVal >= 3000 && intVal <= 3005) {
            if (isRemovalOut) *isRemovalOut = YES;
            return intVal;
        }
        if (intVal >= 0 && intVal <= 5) {
            return 2000 + intVal;
        }
    }
    
    BOOL isRemoval = NO;
    if ([clean hasPrefix:@"remove "] || [clean hasPrefix:@"remove_"] || [clean hasPrefix:@"remove-"]) {
        isRemoval = YES;
        clean = [clean substringFromIndex:7];
    } else if ([clean hasPrefix:@"un"] && clean.length > 2) {
        isRemoval = YES;
        clean = [clean substringFromIndex:2];
    } else if ([clean hasPrefix:@"-"]) {
        isRemoval = YES;
        clean = [clean substringFromIndex:1];
    }
    if (isRemovalOut && isRemoval) *isRemovalOut = YES;
    
    int64_t base = 0;
    if ([clean isEqualToString:@"love"] || [clean isEqualToString:@"heart"] || [clean isEqualToString:@"loved"]) {
        base = 2000;
    } else if ([clean isEqualToString:@"like"] || [clean isEqualToString:@"thumbsup"] || [clean isEqualToString:@"thumbs_up"] || [clean isEqualToString:@"thumbs-up"] || [clean isEqualToString:@"thumbup"] || [clean isEqualToString:@"liked"]) {
        base = 2001;
    } else if ([clean isEqualToString:@"dislike"] || [clean isEqualToString:@"thumbsdown"] || [clean isEqualToString:@"thumbs_down"] || [clean isEqualToString:@"thumbs-down"] || [clean isEqualToString:@"thumbdown"] || [clean isEqualToString:@"disliked"]) {
        base = 2002;
    } else if ([clean isEqualToString:@"laugh"] || [clean isEqualToString:@"haha"] || [clean isEqualToString:@"ha"] || [clean isEqualToString:@"laughed"]) {
        base = 2003;
    } else if ([clean isEqualToString:@"emphasize"] || [clean isEqualToString:@"exclamation"] || [clean isEqualToString:@"exclaim"] || [clean isEqualToString:@"!"] || [clean isEqualToString:@"!!"] || [clean isEqualToString:@"emphasized"]) {
        base = 2004;
    } else if ([clean isEqualToString:@"question"] || [clean isEqualToString:@"questionmark"] || [clean isEqualToString:@"question_mark"] || [clean isEqualToString:@"?"] || [clean isEqualToString:@"questioned"]) {
        base = 2005;
    }
    
    if (base == 0) return 0;
    return isRemoval ? (base + 1000) : base;
}

+ (NSString *)nameForTapbackType:(int64_t)type {
    switch (type) {
        case 2000: return @"Love";
        case 2001: return @"Like";
        case 2002: return @"Dislike";
        case 2003: return @"Laugh";
        case 2004: return @"Emphasize";
        case 2005: return @"Question";
        case 3000: return @"Remove Love";
        case 3001: return @"Remove Like";
        case 3002: return @"Remove Dislike";
        case 3003: return @"Remove Laugh";
        case 3004: return @"Remove Emphasize";
        case 3005: return @"Remove Question";
        default: return [NSString stringWithFormat:@"Unknown (%lld)", (long long)type];
    }
}

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
    int64_t tapbackType = [RelayServer parseTapbackType:tapbackVal isRemoval:&parsedRemoval];
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
    
    IMDaemonController *dc = [IMDaemonController sharedController];
    if (![dc isConnected]) {
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
    
    IMChatRegistry *registry = [IMChatRegistry sharedInstance];
    IMChat *chat = nil;
    
    if (chatGUID && chatGUID.length > 0) {
        chat = [registry existingChatWithGUID:chatGUID];
        if (!chat) {
            chat = [registry existingChatWithChatIdentifier:chatGUID];
        }
    }
    
    if (!chat && recipient && recipient.length > 0) {
        chat = [registry existingChatWithChatIdentifier:recipient];
        if (!chat) {
            IMAccount *account = [self getBestSendingAccount];
            if (!account) {
                [self sendJSONResponse:@{@"error": @"No active or operational iMessage/SMS account available"} statusCode:503 clientFd:clientFd];
                return;
            }
            IMHandle *handle = [account imHandleWithID:recipient];
            if (!handle) {
                [self sendJSONResponse:@{@"error": [NSString stringWithFormat:@"Failed to create IMHandle for '%@'", recipient]} statusCode:400 clientFd:clientFd];
                return;
            }
            chat = [registry chatForIMHandle:handle];
        }
    }
    
    if (!chat) {
        [self sendJSONResponse:@{
            @"error": @"Failed to resolve or create IMChat target",
            @"recipient": recipient ?: [NSNull null],
            @"chat_guid": chatGUID ?: [NSNull null]
        } statusCode:404 clientFd:clientFd];
        return;
    }
    
    // Generate backward compatibility summary text
    NSString *compatString = nil;
    if (originalText && originalText.length > 0) {
        NSString *quoteText = (originalText.length > 30) ? [NSString stringWithFormat:@"%@…", [originalText substringToIndex:30]] : originalText;
        switch (tapbackType) {
            case 2000: compatString = [NSString stringWithFormat:@"Loved “%@”", quoteText]; break;
            case 2001: compatString = [NSString stringWithFormat:@"Liked “%@”", quoteText]; break;
            case 2002: compatString = [NSString stringWithFormat:@"Disliked “%@”", quoteText]; break;
            case 2003: compatString = [NSString stringWithFormat:@"Laughed at “%@”", quoteText]; break;
            case 2004: compatString = [NSString stringWithFormat:@"Emphasized “%@”", quoteText]; break;
            case 2005: compatString = [NSString stringWithFormat:@"Questioned “%@”", quoteText]; break;
            case 3000: compatString = [NSString stringWithFormat:@"Removed a heart from “%@”", quoteText]; break;
            case 3001: compatString = [NSString stringWithFormat:@"Removed a like from “%@”", quoteText]; break;
            case 3002: compatString = [NSString stringWithFormat:@"Removed a dislike from “%@”", quoteText]; break;
            case 3003: compatString = [NSString stringWithFormat:@"Removed a laugh from “%@”", quoteText]; break;
            case 3004: compatString = [NSString stringWithFormat:@"Removed an exclamation from “%@”", quoteText]; break;
            case 3005: compatString = [NSString stringWithFormat:@"Removed a question mark from “%@”", quoteText]; break;
        }
    }
    
    if (!compatString) {
        Class helperCls = NSClassFromString(@"IMMessageAcknowledgmentStringHelper");
        SEL sel = NSSelectorFromString(@"generateBackwardCompatibilityStringForMessageAcknowledgmentType:messageSummaryInfo:");
        if (helperCls && [helperCls respondsToSelector:sel]) {
            NSMethodSignature *sig = [helperCls methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:helperCls];
                [inv setSelector:sel];
                [inv setArgument:&tapbackType atIndex:2];
                NSDictionary *emptyInfo = @{};
                [inv setArgument:&emptyInfo atIndex:3];
                [inv invoke];
                void *retVal = NULL;
                [inv getReturnValue:&retVal];
                if (retVal) {
                    compatString = (__bridge NSString *)retVal;
                }
            }
        }
    }
    if (!compatString || compatString.length == 0) {
        compatString = [RelayServer nameForTapbackType:tapbackType];
    }
    
    NSAttributedString *attrContent = [[NSAttributedString alloc] initWithString:compatString ?: @""];
    IMMessage *reactMsg = [IMMessage instantMessageWithAssociatedMessageContent:attrContent
                                                                          flags:0x5
                                                          associatedMessageGUID:associatedGUID
                                                          associatedMessageType:tapbackType
                                                         associatedMessageRange:NSMakeRange(0, 0)
                                                             messageSummaryInfo:@{}
                                                               threadIdentifier:nil];
    
    if (!reactMsg) {
        [self sendJSONResponse:@{@"error": @"Failed to instantiate associated IMMessage"} statusCode:500 clientFd:clientFd];
        return;
    }
    
    NSLog(@"[+] Dispatching reaction '%@' (code %lld, GUID: %@) -> associated '%@' in chat '%@'",
          [RelayServer nameForTapbackType:tapbackType], (long long)tapbackType, reactMsg.guid, associatedGUID, chat.chatIdentifier ?: chat.guid);
    
    [chat sendMessage:reactMsg];
    
    NSDictionary *response = @{
        @"status": @"success",
        @"message_guid": reactMsg.guid ?: [NSNull null],
        @"original_message_guid": rawGUID,
        @"associated_message_guid": associatedGUID,
        @"tapback_type": [RelayServer nameForTapbackType:tapbackType],
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

- (void)handleStatusRequest:(int)clientFd {
    IMDaemonController *dc = [IMDaemonController sharedController];
    IMAccountController *ac = [IMAccountController sharedInstance];
    IMChatRegistry *cr = [IMChatRegistry sharedInstance];
    
    NSMutableArray *accInfo = [NSMutableArray array];
    IMAccount *activeIMessage = nil;
    for (IMAccount *acc in ac.activeAccounts) {
        [accInfo addObject:@{
            @"login": acc.login ?: @"",
            @"service": acc.serviceName ?: @"",
            @"connected": @(acc.isConnected),
            @"uniqueID": acc.uniqueID ?: @""
        }];
        if ([acc.serviceName isEqualToString:@"iMessage"]) {
            activeIMessage = acc;
        }
    }
    
    NSDictionary *status = @{
        @"status": @"online",
        @"daemon_name": @"crapple-relay-12",
        @"version": @"macOS 12.7.6 (Monterey)",
        @"security": @{
            @"bound_host": self.host,
            @"incoming_port": @(self.port),
            @"auth_type": @"Bearer Token"
        },
        @"outgoing_webhook": @{
            @"url": self.webhookURL,
            @"default_port": @(5569),
            @"auth_configured": @(self.webhookToken.length > 0)
        },
        @"incoming_observer_active": @(YES),
        @"daemon_connected": @([dc isConnected]),
        @"listener_id": [dc _listenerID] ?: @"",
        @"imessage_account": activeIMessage ? @{
            @"login": activeIMessage.login ?: @"",
            @"service": activeIMessage.serviceName ?: @"",
            @"connected": @(activeIMessage.isConnected),
            @"uniqueID": activeIMessage.uniqueID ?: @""
        } : [NSNull null],
        @"active_accounts_count": @(ac.activeAccounts.count),
        @"total_chats": @([cr numberOfExistingChats]),
        @"accounts": accInfo
    };
    
    [self sendJSONResponse:status statusCode:200 clientFd:clientFd];
}

- (void)handleChatsRequest:(int)clientFd {
    @try {
        IMChatRegistry *cr = [IMChatRegistry sharedInstance];
        NSArray<IMChat *> *allChats = [cr allExistingChats];
        NSMutableArray *chatList = [NSMutableArray array];
        
        for (IMChat *chat in allChats) {
            NSString *guid = [chat respondsToSelector:@selector(guid)] ? (chat.guid ?: @"") : @"";
            NSString *ident = [chat respondsToSelector:@selector(chatIdentifier)] ? (chat.chatIdentifier ?: @"") : @"";
            NSString *dispName = [chat respondsToSelector:@selector(displayName)] ? (chat.displayName ?: @"") : @"";
            NSString *recip = ([chat respondsToSelector:@selector(recipient)] && chat.recipient) ? (chat.recipient.ID ?: @"") : @"";
            NSString *lastHandle = [chat respondsToSelector:@selector(lastAddressedHandleID)] ? ([chat lastAddressedHandleID] ?: @"") : @"";
            
            [chatList addObject:@{
                @"guid": guid,
                @"identifier": ident,
                @"displayName": dispName,
                @"recipient": recip,
                @"last_addressed_handle": lastHandle
            }];
        }
        
        [self sendJSONResponse:@{@"chats": chatList, @"count": @(chatList.count)} statusCode:200 clientFd:clientFd];
    } @catch (NSException *ex) {
        NSLog(@"[ERROR] Exception in handleChatsRequest: %@", ex);
        [self sendJSONResponse:@{@"error": @"Failed to query chats", @"reason": ex.reason ?: @""} statusCode:500 clientFd:clientFd];
    }
}

- (void)handleAccountsRequest:(int)clientFd {
    IMAccountController *ac = [IMAccountController sharedInstance];
    NSMutableArray *accounts = [NSMutableArray array];
    
    for (IMAccount *acc in ac.activeAccounts) {
        [accounts addObject:@{
            @"uniqueID": acc.uniqueID ?: @"",
            @"login": acc.login ?: @"",
            @"serviceName": acc.serviceName ?: @"",
            @"isConnected": @(acc.isConnected),
            @"isOperational": @(acc.isOperational)
        }];
    }
    
    [self sendJSONResponse:@{@"accounts": accounts, @"count": @(accounts.count)} statusCode:200 clientFd:clientFd];
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

void sigHandler(int sig) {
    NSLog(@"[+] Caught signal %d, shutting down cleanly...", sig);
    if (g_server) {
        [g_server stop];
    }
    closelog();
    exit(0);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        openlog("imessage-relay", LOG_PID, LOG_DAEMON);
        signal(SIGINT, sigHandler);
        signal(SIGTERM, sigHandler);
        signal(SIGPIPE, SIG_IGN);
        
        int port = kDefaultPort; // default incoming port: 5569
        NSString *token = nil;
        NSString *webhookURL = nil;
        NSString *webhookToken = nil;
        NSString *host = nil;
        
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if (([arg isEqualToString:@"-p"] || [arg isEqualToString:@"--port"]) && i + 1 < argc) {
                port = atoi(argv[++i]);
            } else if (([arg isEqualToString:@"-h"] || [arg isEqualToString:@"--host"]) && i + 1 < argc) {
                host = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-t"] || [arg isEqualToString:@"--token"]) && i + 1 < argc) {
                token = [NSString stringWithUTF8String:argv[++i]];
            } else if (([arg isEqualToString:@"-w"] || [arg isEqualToString:@"--webhook"]) && i + 1 < argc) {
                webhookURL = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--webhook-token"] && i + 1 < argc) {
                webhookToken = [NSString stringWithUTF8String:argv[++i]];
            }
        }
        
        char *envHost = getenv("RELAY_HOST");
        if (envHost && (!host || host.length == 0)) host = [NSString stringWithUTF8String:envHost];
        if (!host || host.length == 0) host = [RelayServer resolveDefaultIP];
        
        char *envPort = getenv("RELAY_PORT");
        if (envPort) port = atoi(envPort);
        char *envToken = getenv("RELAY_AUTH_TOKEN");
        if (envToken && (!token || token.length == 0)) token = [NSString stringWithUTF8String:envToken];
        char *envWebhook = getenv("WEBHOOK_URL");
        if (envWebhook && (!webhookURL || webhookURL.length == 0)) webhookURL = [NSString stringWithUTF8String:envWebhook];
        if (!webhookURL || webhookURL.length == 0) webhookURL = kDefaultWebhookURL;
        char *envWebhookToken = getenv("WEBHOOK_AUTH_TOKEN");
        if (envWebhookToken && (!webhookToken || webhookToken.length == 0)) webhookToken = [NSString stringWithUTF8String:envWebhookToken];
        
        if (!token || token.length == 0) {
            token = [[NSUUID UUID] UUIDString];
            NSLog(@"[SECURITY] No RELAY_AUTH_TOKEN or --token specified. Generated ephemeral Bearer token: %@", token);
        }
        if (!webhookToken || webhookToken.length == 0) {
            webhookToken = token;
        }
        
        NSLog(@"==================================================");
        NSLog(@" macOS 12.7 (Monterey) Native iMessage Relay Daemon");
        NSLog(@" Default Ports: Incoming %d, Outgoing Webhook 5569", port);
        NSLog(@" Network Bind: %@ | Bearer Auth: Active", host);
        NSLog(@"==================================================");
        
        // 1. Connect to IMDaemonController with full capabilities
        NSLog(@"[+] Step 1: Connecting to IMDaemonController...");
        IMDaemonController *dc = [IMDaemonController sharedController];
        unsigned int allCaps = kFZListenerCapAccounts | kFZListenerCapChats | kFZListenerCapFileTransfers | kFZListenerCapSendMessages | kFZListenerCapManageStatus;
        [dc addListenerID:@"crapple-relay-listener" capabilities:allCaps];
        [dc connectToDaemonWithLaunch:YES capabilities:allCaps blockUntilConnected:YES];
        NSLog(@"[+] IMDaemonController isConnected: %d (listenerID: %@, capabilities: 0x%x)", 
              [dc isConnected], [dc _listenerID], [dc capabilities]);
        
        // 2. Initialize IMChatRegistry
        NSLog(@"[+] Step 2: Initializing IMChatRegistry...");
        [IMChatRegistry sharedInstance];
        NSLog(@"[+] IMChatRegistry initialized.");
        
        // 3. Log discovered accounts
        IMAccountController *ac = [IMAccountController sharedInstance];
        NSLog(@"[+] Active accounts discovered: %lu", (unsigned long)[ac activeAccounts].count);
        for (IMAccount *acc in [ac activeAccounts]) {
            NSLog(@"    -> %@ [%@] (login: %@, connected: %d)", acc.uniqueID, acc.serviceName, acc.login, acc.isConnected);
        }
        
        // 4. Start Relay HTTP Server
        NSLog(@"[+] Step 4: Starting HTTP listener on %@:%d...", host, port);
        g_server = [[RelayServer alloc] initWithHost:host 
                                                port:port 
                                         bearerToken:token 
                                          webhookURL:webhookURL 
                                        webhookToken:webhookToken];
        if (![g_server start]) {
            NSLog(@"[FATAL] Could not start HTTP listener on %@:%d", host, port);
            return 1;
        }
        
        NSLog(@"[+] Daemon initialized successfully. Entering main run loop.");
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
