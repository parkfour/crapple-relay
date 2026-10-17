#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void RelayLogInit(const char *ident);
void RelayLogClose(void);
void RelayLog(NSString *format, ...);

#undef NSLog
#define NSLog(fmt, ...) RelayLog((fmt), ##__VA_ARGS__)

NS_ASSUME_NONNULL_END
