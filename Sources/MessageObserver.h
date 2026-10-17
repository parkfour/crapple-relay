#import <Foundation/Foundation.h>
#import "Headers/IMCoreBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface MessageObserver : NSObject

@property (nonatomic, copy) NSString *webhookURL;
@property (nonatomic, copy) NSString *webhookToken;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) int64_t lastProcessedRowID;

+ (instancetype)sharedInstance;

- (void)startWithWebhookURL:(NSString *)webhookURL
               webhookToken:(NSString *)webhookToken
               pollInterval:(NSTimeInterval)interval;

- (void)stop;

- (void)dispatchWebhookWithPayload:(NSDictionary *)payload;
- (void)checkDatabaseForNewMessages;

- (nullable NSDictionary *)retryLastIncomingMessageWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
