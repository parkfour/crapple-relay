#import <Foundation/Foundation.h>
#import "Headers/IMCoreBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface IMServiceManager : NSObject

+ (instancetype)sharedInstance;

/// Initializes connection to IMDaemonController with required capabilities
- (BOOL)connectToDaemonWithListenerID:(NSString *)listenerID;
- (BOOL)isConnected;

/// Account management
- (nullable IMAccount *)bestSendingAccount;
- (NSArray<NSDictionary *> *)accountsInfoList;
- (NSUInteger)activeAccountsCount;

/// Chat resolution
- (nullable IMChat *)resolveChatForRecipient:(nullable NSString *)recipient
                                    chatGUID:(nullable NSString *)chatGUID;
- (NSArray<NSDictionary *> *)allChatsInfoList;
- (NSArray<NSString *> *)participantsForChat:(nullable IMChat *)chat
                              chatIdentifier:(nullable NSString *)chatIdentifier
                                    chatGUID:(nullable NSString *)chatGUID;
- (NSUInteger)totalChatsCount;

/// Outbound messaging
- (nullable NSString *)registerFileTransferWithData:(NSData *)data
                                           filename:(nullable NSString *)filename
                                           mimeType:(nullable NSString *)mimeType
                                      savedFilename:(NSString * _Nullable * _Nullable)outFilename
                                              error:(NSError **)error;

- (nullable IMMessage *)sendMessageToChat:(IMChat *)chat
                                     text:(nullable NSString *)text
                                  subject:(nullable NSString *)subject
                             transferGUID:(nullable NSString *)transferGUID
                            cleanFilename:(nullable NSString *)cleanFilename
                                 threadID:(nullable NSString *)threadID
                                    error:(NSError **)error;

/// Tapback / Reaction Handling
+ (int64_t)parseTapbackType:(id)tapbackVal isRemoval:(BOOL *)isRemovalOut;
+ (NSString *)nameForTapbackType:(int64_t)type;
+ (NSString *)backwardCompatibilityStringForType:(int64_t)type originalText:(nullable NSString *)originalText;

- (nullable IMMessage *)sendTapbackToChat:(IMChat *)chat
                           associatedGUID:(NSString *)associatedGUID
                              tapbackType:(int64_t)tapbackType
                             compatString:(NSString *)compatString
                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
