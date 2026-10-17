#import "RelayLogger.h"
#import <syslog.h>
#import <os/log.h>
#import <unistd.h>

static os_log_t g_relay_log = NULL;

void RelayLogInit(const char *ident) {
    if (!ident) ident = "imessage-relay";
    openlog(ident, LOG_PID, LOG_DAEMON);
    if (!g_relay_log) {
        g_relay_log = os_log_create("com.crapple.imessage-relay", "daemon");
    }
}

void RelayLogClose(void) {
    closelog();
}

void RelayLog(NSString *format, ...) {
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
