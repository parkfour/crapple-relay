#import "IMServiceManager.h"
#import "RelayLogger.h"
#import <sys/stat.h>

@implementation IMServiceManager

+ (instancetype)sharedInstance {
    static IMServiceManager *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[IMServiceManager alloc] init];
    });
    return s_instance;
}

- (BOOL)connectToDaemonWithListenerID:(NSString *)listenerID {
    IMDaemonController *dc = [IMDaemonController sharedController];
    unsigned int allCaps = kFZListenerCapAccounts | kFZListenerCapChats | kFZListenerCapFileTransfers | kFZListenerCapSendMessages | kFZListenerCapManageStatus;
    
    [dc addListenerID:listenerID capabilities:allCaps];
    BOOL connected = [dc connectToDaemonWithLaunch:YES capabilities:allCaps blockUntilConnected:YES];
    
    // Initialize IMChatRegistry
    [IMChatRegistry sharedInstance];
    
    return connected;
}

- (BOOL)isConnected {
    return [[IMDaemonController sharedController] isConnected];
}

#pragma mark - Account Management

- (nullable IMAccount *)bestSendingAccount {
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

- (NSArray<NSDictionary *> *)accountsInfoList {
    IMAccountController *ac = [IMAccountController sharedInstance];
    NSMutableArray *accInfo = [NSMutableArray array];
    
    for (IMAccount *acc in ac.activeAccounts) {
        [accInfo addObject:@{
            @"login": acc.login ?: @"",
            @"service": acc.serviceName ?: @"",
            @"connected": @(acc.isConnected),
            @"uniqueID": acc.uniqueID ?: @""
        }];
    }
    return accInfo;
}

- (NSUInteger)activeAccountsCount {
    return [IMAccountController sharedInstance].activeAccounts.count;
}

#pragma mark - Chat Resolution

- (nullable IMChat *)resolveChatForRecipient:(nullable NSString *)recipient
                                    chatGUID:(nullable NSString *)chatGUID {
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
            IMAccount *account = [self bestSendingAccount];
            if (account) {
                IMHandle *handle = [account imHandleWithID:recipient];
                if (handle) {
                    chat = [registry chatForIMHandle:handle];
                }
            }
        }
    }
    
    return chat;
}

- (NSArray<NSDictionary *> *)allChatsInfoList {
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
    return chatList;
}

- (NSUInteger)totalChatsCount {
    return [[IMChatRegistry sharedInstance] numberOfExistingChats];
}

#pragma mark - Outbound Messaging

- (nullable NSString *)registerFileTransferWithData:(NSData *)data
                                           filename:(nullable NSString *)filename
                                           mimeType:(nullable NSString *)mimeType
                                      savedFilename:(NSString * _Nullable * _Nullable)outFilename
                                              error:(NSError **)error {
    NSString *cleanName = nil;
    if (filename && filename.length > 0) {
        cleanName = [filename lastPathComponent];
    }
    if (!cleanName || cleanName.length == 0) {
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
        cleanName = [NSString stringWithFormat:@"attachment.%@", ext];
    }
    
    if (outFilename) *outFilename = cleanName;
    
    NSString *uniqueName = [NSString stringWithFormat:@"%@_%@", [[NSUUID UUID] UUIDString], cleanName];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:uniqueName];
    
    if (![data writeToFile:tempPath atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"IMServiceManager" code:101 userInfo:@{NSLocalizedDescriptionKey: @"Failed to write attachment to temporary disk storage"}];
        }
        return nil;
    }
    
    chmod([tempPath UTF8String], 0644);
    
    NSURL *fileURL = [NSURL fileURLWithPath:tempPath];
    IMFileTransferCenter *transferCenter = [IMFileTransferCenter sharedInstance];
    NSString *transferGUID = [transferCenter guidForNewOutgoingTransferWithLocalURL:fileURL];
    if (!transferGUID || transferGUID.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"IMServiceManager" code:102 userInfo:@{NSLocalizedDescriptionKey: @"IMFileTransferCenter failed to generate transfer GUID"}];
        }
        return nil;
    }
    
    IMFileTransfer *transfer = [transferCenter transferForGUID:transferGUID];
    if (cleanName && [transfer respondsToSelector:@selector(setFilename:)]) {
        [transfer setFilename:cleanName];
    }
    if (mimeType && [transfer respondsToSelector:@selector(setMimeType:)]) {
        [transfer setMimeType:mimeType];
    }
    
    [transferCenter registerTransferWithDaemon:transferGUID];
    return transferGUID;
}

- (nullable IMMessage *)sendMessageToChat:(IMChat *)chat
                                     text:(nullable NSString *)text
                                  subject:(nullable NSString *)subject
                             transferGUID:(nullable NSString *)transferGUID
                            cleanFilename:(nullable NSString *)cleanFilename
                                 threadID:(nullable NSString *)threadID
                                    error:(NSError **)error {
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
        
        if (text && text.length > 0) {
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
                                   threadIdentifier:threadID];
    } else {
        message = [IMMessage instantMessageWithText:attrText
                                     messageSubject:attrSubject
                                              flags:messageFlags
                                   threadIdentifier:threadID];
    }
    
    if (!message) {
        if (error) {
            *error = [NSError errorWithDomain:@"IMServiceManager" code:103 userInfo:@{NSLocalizedDescriptionKey: @"Failed to instantiate IMMessage"}];
        }
        return nil;
    }
    
    [chat sendMessage:message];
    return message;
}

#pragma mark - Tapbacks / Reactions

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

+ (NSString *)backwardCompatibilityStringForType:(int64_t)type originalText:(nullable NSString *)originalText {
    if (originalText && originalText.length > 0) {
        NSString *quoteText = (originalText.length > 30) ? [NSString stringWithFormat:@"%@…", [originalText substringToIndex:30]] : originalText;
        switch (type) {
            case 2000: return [NSString stringWithFormat:@"Loved “%@”", quoteText];
            case 2001: return [NSString stringWithFormat:@"Liked “%@”", quoteText];
            case 2002: return [NSString stringWithFormat:@"Disliked “%@”", quoteText];
            case 2003: return [NSString stringWithFormat:@"Laughed at “%@”", quoteText];
            case 2004: return [NSString stringWithFormat:@"Emphasized “%@”", quoteText];
            case 2005: return [NSString stringWithFormat:@"Questioned “%@”", quoteText];
            case 3000: return [NSString stringWithFormat:@"Removed a heart from “%@”", quoteText];
            case 3001: return [NSString stringWithFormat:@"Removed a like from “%@”", quoteText];
            case 3002: return [NSString stringWithFormat:@"Removed a dislike from “%@”", quoteText];
            case 3003: return [NSString stringWithFormat:@"Removed a laugh from “%@”", quoteText];
            case 3004: return [NSString stringWithFormat:@"Removed an exclamation from “%@”", quoteText];
            case 3005: return [NSString stringWithFormat:@"Removed a question mark from “%@”", quoteText];
        }
    }
    
    // Fallback to IMMessageAcknowledgmentStringHelper
    Class helperCls = NSClassFromString(@"IMMessageAcknowledgmentStringHelper");
    SEL sel = NSSelectorFromString(@"generateBackwardCompatibilityStringForMessageAcknowledgmentType:messageSummaryInfo:");
    if (helperCls && [helperCls respondsToSelector:sel]) {
        NSMethodSignature *sig = [helperCls methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:helperCls];
            [inv setSelector:sel];
            [inv setArgument:&type atIndex:2];
            NSDictionary *emptyInfo = @{};
            [inv setArgument:&emptyInfo atIndex:3];
            [inv invoke];
            void *retVal = NULL;
            [inv getReturnValue:&retVal];
            if (retVal) {
                return (__bridge NSString *)retVal;
            }
        }
    }
    
    return [self nameForTapbackType:type];
}

- (nullable IMMessage *)sendTapbackToChat:(IMChat *)chat
                           associatedGUID:(NSString *)associatedGUID
                              tapbackType:(int64_t)tapbackType
                             compatString:(NSString *)compatString
                                    error:(NSError **)error {
    NSAttributedString *attrContent = [[NSAttributedString alloc] initWithString:compatString ?: @""];
    IMMessage *reactMsg = [IMMessage instantMessageWithAssociatedMessageContent:attrContent
                                                                          flags:0x5
                                                          associatedMessageGUID:associatedGUID
                                                          associatedMessageType:tapbackType
                                                         associatedMessageRange:NSMakeRange(0, 0)
                                                             messageSummaryInfo:@{}
                                                               threadIdentifier:nil];
    
    if (!reactMsg) {
        if (error) {
            *error = [NSError errorWithDomain:@"IMServiceManager" code:104 userInfo:@{NSLocalizedDescriptionKey: @"Failed to instantiate associated IMMessage"}];
        }
        return nil;
    }
    
    [chat sendMessage:reactMsg];
    return reactMsg;
}

@end
