#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forward Declarations
@class IMHandle;
@class IMAccount;
@class IMAccountController;
@class IMChat;
@class IMChatRegistry;
@class IMMessage;
@class IMService;
@class IMDaemonController;
@class IMFileTransfer;
@class IMFileTransferCenter;

// ==========================================
// IMFileTransfer & IMFileTransferCenter
// ==========================================
@interface IMFileTransfer : NSObject
@property (retain, nonatomic) NSString *filename;
@property (retain, nonatomic) NSString *mimeType;
@property (readonly, nonatomic) NSString *guid;
@property (readonly, nonatomic) NSURL *localURL;
@property (readonly, nonatomic) NSString *localPath;
@property (readonly, nonatomic) unsigned long long totalBytes;
@end

@interface IMFileTransferCenter : NSObject
+ (instancetype)sharedInstance;
- (nullable NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url;
- (nullable NSString *)guidForNewOutgoingTransferWithLocalURL:(NSURL *)url useLegacyGuid:(BOOL)legacy;
- (nullable IMFileTransfer *)transferForGUID:(NSString *)guid;
- (void)registerTransferWithDaemon:(NSString *)guid;
- (NSDictionary *)transfers;
@end

// ==========================================
// IMService
// ==========================================
@interface IMService : NSObject
+ (nullable IMService *)iMessageService;
+ (nullable IMService *)smsService;
+ (NSArray<IMService *> *)allServices;
+ (nullable IMService *)serviceWithName:(NSString *)name;
- (NSString *)name;
- (NSString *)internalName;
- (BOOL)isEnabled;
@end

// ==========================================
// IMHandle
// ==========================================
@interface IMHandle : NSObject
@property (readonly, nonatomic) NSString *ID;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) NSString *displayID;
@property (readonly, nonatomic) NSString *normalizedID;
@property (readonly, nonatomic) IMAccount *account;
@property (readonly, nonatomic) IMService *service;
- (NSString *)fullName;
- (BOOL)isLoginIMHandle;
@end

// ==========================================
// IMAccount
// ==========================================
@interface IMAccount : NSObject
@property (readonly, nonatomic) NSString *uniqueID;
@property (readonly, nonatomic) NSString *serviceName;
@property (readonly, nonatomic) NSString *login;
@property (readonly, nonatomic) IMService *service;
@property (readonly, nonatomic) BOOL isConnected;
@property (readonly, nonatomic) BOOL isActive;
@property (readonly, nonatomic) BOOL isOperational;
- (nullable IMHandle *)imHandleWithID:(NSString *)handleID;
- (nullable IMHandle *)imHandleWithID:(NSString *)handleID alreadyCanonical:(BOOL)canonical;
- (nullable IMHandle *)loginIMHandle;
- (NSArray<IMHandle *> *)arrayOfAllIMHandles;
@end

// ==========================================
// IMAccountController
// ==========================================
@interface IMAccountController : NSObject
+ (instancetype)sharedInstance;
@property (readonly, nonatomic) NSArray<IMAccount *> *activeAccounts;
@property (readonly, nonatomic) NSArray<IMAccount *> *connectedAccounts;
@property (readonly, nonatomic) NSArray<IMAccount *> *operationalAccounts;
@property (readonly, nonatomic, nullable) IMAccount *activeIMessageAccount;
@property (readonly, nonatomic, nullable) IMAccount *activeSMSAccount;
- (nullable IMAccount *)bestAccountForService:(IMService *)service;
- (nullable IMAccount *)bestOperationalAccountForService:(IMService *)service;
- (nullable IMAccount *)bestActiveAccountForService:(IMService *)service;
- (nullable IMAccount *)accountForUniqueID:(NSString *)uniqueID;
@end

// ==========================================
// IMMessage
// ==========================================
@interface IMMessage : NSObject
@property (readonly, nonatomic) NSString *guid;
@property (readonly, nonatomic) NSAttributedString *text;
@property (readonly, nonatomic, nullable) NSAttributedString *messageSubject;
@property (readonly, nonatomic) IMHandle *sender;
@property (readonly, nonatomic) NSDate *time;
@property (readonly, nonatomic) NSUInteger flags;
@property (readonly, nonatomic) BOOL isFinished;
@property (readonly, nonatomic) BOOL isFromMe;
@property (readonly, nonatomic, nullable) NSString *plainBody;
@property (readonly, nonatomic, nullable) NSArray<NSString *> *fileTransferGUIDs;
@property (readonly, nonatomic) BOOL hasInlineAttachments;

@property (readonly, nonatomic) BOOL isAssociatedMessage;
@property (readonly, nonatomic, nullable) NSString *associatedMessageGUID;
@property (readonly, nonatomic) int64_t associatedMessageType;
@property (readonly, nonatomic) NSRange associatedMessageRange;

+ (instancetype)instantMessageWithText:(NSAttributedString *)text
                                 flags:(NSUInteger)flags;

+ (instancetype)instantMessageWithText:(NSAttributedString *)text
                        messageSubject:(nullable NSAttributedString *)subject
                                 flags:(NSUInteger)flags;

+ (instancetype)instantMessageWithText:(NSAttributedString *)text
                        messageSubject:(nullable NSAttributedString *)subject
                     fileTransferGUIDs:(nullable NSArray<NSString *> *)fileTransferGUIDs
                                 flags:(NSUInteger)flags
                      threadIdentifier:(nullable NSString *)threadIdentifier;

+ (instancetype)instantMessageWithText:(NSAttributedString *)text
                        messageSubject:(nullable NSAttributedString *)subject
                                 flags:(NSUInteger)flags
                      threadIdentifier:(nullable NSString *)threadIdentifier;

+ (instancetype)instantMessageWithText:(NSAttributedString *)text
                                 flags:(NSUInteger)flags
                      threadIdentifier:(nullable NSString *)threadIdentifier;

+ (instancetype)instantMessageWithAssociatedMessageContent:(nullable NSAttributedString *)content
                                                     flags:(NSUInteger)flags
                                     associatedMessageGUID:(NSString *)guid
                                     associatedMessageType:(int64_t)type
                                    associatedMessageRange:(NSRange)range
                                        messageSummaryInfo:(nullable NSDictionary *)summaryInfo
                                          threadIdentifier:(nullable NSString *)threadIdentifier;
@end

// ==========================================
// IMChat
// ==========================================
@interface IMChat : NSObject
@property (readonly, nonatomic) NSString *guid;
@property (readonly, nonatomic) NSString *chatIdentifier;
@property (readonly, nonatomic, nullable) NSString *displayName;
@property (readonly, nonatomic) IMAccount *account;
@property (readonly, nonatomic, nullable) IMHandle *recipient;
@property (readonly, nonatomic) NSArray<IMHandle *> *participants;
@property (readonly, nonatomic, nullable) NSString *lastAddressedHandleID;
@property (readonly, nonatomic, nullable) IMMessage *lastMessage;
@property (readonly, nonatomic, nullable) IMMessage *lastIncomingMessage;

- (void)sendMessage:(IMMessage *)message;
- (BOOL)canSendMessage:(IMMessage *)message;
- (void)startTyping;
- (void)stopTyping;
- (BOOL)isGroupChat;
- (nullable NSArray<NSString *> *)participantHandleIDs;
@end

// ==========================================
// IMChatRegistry
// ==========================================
@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
@property (readonly, nonatomic) NSArray<IMChat *> *allExistingChats;
@property (readonly, nonatomic) NSUInteger numberOfExistingChats;

- (nullable IMChat *)chatForIMHandle:(IMHandle *)handle;
- (nullable IMChat *)chatForIMHandles:(NSArray<IMHandle *> *)handles;
- (nullable IMChat *)chatForIMHandles:(NSArray<IMHandle *> *)handles chatName:(nullable NSString *)name;
- (nullable IMChat *)existingChatWithChatIdentifier:(NSString *)identifier;
- (nullable IMChat *)existingChatWithGUID:(NSString *)guid;
- (nullable IMChat *)existingChatForIMHandle:(IMHandle *)handle;
- (nullable IMChat *)existingChatForIMHandles:(NSArray<IMHandle *> *)handles;
- (void)setupComplete;
- (void)account:(id)account chat:(id)chat style:(unsigned char)style chatProperties:(nullable id)props groupID:(nullable id)gid chatPersonCentricID:(nullable id)cid messageReceived:(id)msg;
@end

// ==========================================
// IMDaemonController
// ==========================================
@interface IMDaemonController : NSObject
+ (instancetype)sharedController;
+ (instancetype)sharedInstance;
@property (readonly, nonatomic) BOOL isConnected;
@property (readonly, nonatomic) BOOL isConnecting;
@property (readonly, nonatomic) unsigned int capabilities;
@property (readonly, nonatomic, nullable) NSString *_listenerID;

- (void)addListenerID:(NSString *)listenerID capabilities:(unsigned int)capabilities;
- (void)removeListenerID:(NSString *)listenerID;
- (BOOL)connectToDaemonWithLaunch:(BOOL)launch
                     capabilities:(unsigned int)capabilities
             blockUntilConnected:(BOOL)block;
- (BOOL)connectToDaemonWithLaunch:(BOOL)launch;
- (BOOL)connectToDaemon;
- (BOOL)blockUntilConnected;
- (void)disconnectFromDaemon;
@end

// Notification Constants
extern NSString * const __kIMDaemonDidConnectNotification;
extern NSString * const __kIMDaemonWillConnectNotification;
extern NSString * const __kIMDaemonDidDisconnectNotification;
extern NSString * const __kIMAccountStatusChangedNotification;
extern NSString * const IMChatMessageReceivedNotification;
extern NSString * const IMChatItemsDidChangeNotification;
extern NSString * const IMChatRegistryMessageSentNotification;
extern NSString * const IMFileTransferFinishedNotification;

// Attributed String Attachment Constants (IMFoundation)
extern NSString * const IMFileTransferGUIDAttributeName;
extern NSString * const IMFilenameAttributeName;

// Listener Capability Constants (IMFoundation)
extern unsigned int kFZListenerCapAccounts;
extern unsigned int kFZListenerCapChats;
extern unsigned int kFZListenerCapFileTransfers;
extern unsigned int kFZListenerCapSendMessages;
extern unsigned int kFZListenerCapManageStatus;

NS_ASSUME_NONNULL_END
