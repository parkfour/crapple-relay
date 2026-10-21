#import <Foundation/Foundation.h>
#import "Headers/IMCoreBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface MessageObserver : NSObject

@property (nonatomic, copy) NSString *webhookURL;
@property (nonatomic, copy) NSString *webhookToken;
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) int64_t lastDeliveredRowID;
@property (nonatomic, readonly) int64_t lastProcessedRowID; // Alias for backward compatibility
@property (nonatomic, readonly) NSUInteger consecutiveFailures;
@property (nonatomic, readonly) BOOL isDelivering;
@property (nonatomic, readonly, nullable) NSDate *nextRetryAllowedDate;

+ (instancetype)sharedInstance;

- (void)startWithWebhookURL:(NSString *)webhookURL
               webhookToken:(NSString *)webhookToken
               pollInterval:(NSTimeInterval)interval;

- (void)stop;

- (void)processPendingQueue;
- (void)checkDatabaseForNewMessages; // Alias for processPendingQueue
- (void)resetBackoffAndDrainQueue;
- (void)setDeliveredRowID:(int64_t)rowID;
- (NSUInteger)pendingMessageCount;
- (NSDictionary *)queueStatusInfo;

- (void)dispatchWebhookWithPayload:(NSDictionary *)payload;
- (void)dispatchWebhookWithPayload:(NSDictionary *)payload
                             rowID:(int64_t)rowID
                        completion:(void (^ _Nullable)(BOOL success, NSInteger statusCode, NSError * _Nullable error))completion;

- (nullable NSDictionary *)retryLastIncomingMessageWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
