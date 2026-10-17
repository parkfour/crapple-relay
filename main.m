#import <Foundation/Foundation.h>
#import <signal.h>
#import <unistd.h>

#import "Sources/RelayLogger.h"
#import "Sources/IMServiceManager.h"
#import "Sources/MessageObserver.h"
#import "Sources/HTTPServer.h"

// Default Configuration Constants
static const int kDefaultPort = 5569;
static NSString * const kHardcodedBearerToken = @"your-secure-token-here";
static NSString * const kDefaultWebhookURL = @"http://10.0.0.1:5569/receive-imessage";
static NSString * const kDefaultWebhookToken = @"your-secure-token-here";

static HTTPServer *g_server = nil;

void sigHandler(int sig) {
    NSLog(@"[+] Caught signal %d, shutting down cleanly...", sig);
    if (g_server) {
        [g_server stop];
    }
    [[MessageObserver sharedInstance] stop];
    RelayLogClose();
    exit(0);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        RelayLogInit("imessage-relay");
        
        signal(SIGINT, sigHandler);
        signal(SIGTERM, sigHandler);
        signal(SIGPIPE, SIG_IGN);
        
        int port = kDefaultPort;
        NSString *token = kHardcodedBearerToken;
        NSString *webhookURL = kDefaultWebhookURL;
        NSString *webhookToken = kDefaultWebhookToken;
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
        if (!host || host.length == 0) host = [HTTPServer resolveDefaultIP];
        
        char *envPort = getenv("RELAY_PORT");
        if (envPort) port = atoi(envPort);
        char *envToken = getenv("RELAY_AUTH_TOKEN");
        if (envToken) token = [NSString stringWithUTF8String:envToken];
        char *envWebhook = getenv("WEBHOOK_URL");
        if (envWebhook) webhookURL = [NSString stringWithUTF8String:envWebhook];
        char *envWebhookToken = getenv("WEBHOOK_AUTH_TOKEN");
        if (envWebhookToken) webhookToken = [NSString stringWithUTF8String:envWebhookToken];
        
        NSLog(@"==================================================");
        NSLog(@" macOS 12.7 (Monterey) Native iMessage Relay Daemon");
        NSLog(@" Default Ports: Incoming %d, Outgoing Webhook 5569", port);
        NSLog(@" Network Bind: %@ | Bearer Auth: Active", host);
        NSLog(@"==================================================");
        
        // 1. Connect to IMDaemonController via IMServiceManager
        NSLog(@"[+] Step 1: Connecting to IMDaemonController...");
        IMServiceManager *imManager = [IMServiceManager sharedInstance];
        NSString *listenerID = @"crapple-relay-listener";
        if (![imManager connectToDaemonWithListenerID:listenerID]) {
            NSLog(@"[WARNING] Failed to synchronously connect to imagent. Continuing...");
        }
        NSLog(@"[+] IMDaemonController isConnected: %d (active accounts: %lu, chats: %lu)",
              [imManager isConnected], (unsigned long)[imManager activeAccountsCount], (unsigned long)[imManager totalChatsCount]);
        
        // 2. Start MessageObserver (SQLite chat.db watcher + IMCore notifications)
        NSLog(@"[+] Step 2: Starting MessageObserver...");
        MessageObserver *observer = [MessageObserver sharedInstance];
        [observer startWithWebhookURL:webhookURL webhookToken:webhookToken pollInterval:1.0];
        
        // 3. Start HTTPServer
        NSLog(@"[+] Step 3: Starting HTTP listener on %@:%d...", host, port);
        g_server = [[HTTPServer alloc] initWithHost:host port:port bearerToken:token];
        if (![g_server start]) {
            NSLog(@"[FATAL] Could not start HTTP listener on %@:%d", host, port);
            return 1;
        }
        
        NSLog(@"[+] Daemon initialized successfully. Entering main run loop.");
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
