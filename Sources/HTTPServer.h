#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HTTPServer : NSObject

@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) int port;
@property (nonatomic, copy) NSString *bearerToken;
@property (nonatomic, readonly) BOOL isRunning;

+ (NSString *)resolveDefaultIP;
+ (NSString *)relayVersion;
+ (NSString *)relayGitCommit;

- (instancetype)initWithHost:(nullable NSString *)host
                        port:(int)port
                 bearerToken:(NSString *)bearerToken;

- (BOOL)start;
- (void)stop;

- (void)sendJSONResponse:(id)obj statusCode:(int)statusCode clientFd:(int)clientFd;

@end

NS_ASSUME_NONNULL_END
