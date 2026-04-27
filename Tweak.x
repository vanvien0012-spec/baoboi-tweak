// BaoBoiAgent Tweak - v1.3.0
// Hook NCNotificationRequest để đọc thông báo từ tất cả app trên iPhone
// Nhận token qua URL scheme baoboi://setup?token=TOKEN
// Gửi dữ liệu về dashboard tại baoboidash.com

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

// ─── Cấu hình ────────────────────────────────────────────────────────────────
static NSString *const kServerURL = @"https://baoboidash.com/api/trpc/device.log";
static NSString *const kDeviceTokenKey = @"BaoBoiDeviceToken";

// Lấy deviceToken đã lưu trong UserDefaults
static NSString *getDeviceToken() {
    // Thử cả suite name để đảm bảo đọc được từ mọi process
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

    // Wrap theo tRPC format
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

// Gửi heartbeat ngay sau khi lưu token
static void sendInitialHeartbeat() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        UIDevice *device = [UIDevice currentDevice];
        NSDictionary *payload = @{
            @"event": @"device_online",
            @"deviceName": device.name ?: @"iPhone",
            @"systemVersion": device.systemVersion ?: @"",
            @"model": device.model ?: @"iPhone",
        };
        sendToServer(payload);
    });
}

// ─── Hook URL scheme baoboi:// trên SpringBoard ───────────────────────────────
// SpringBoard xử lý tất cả URL scheme openURL — hook vào đây để bắt baoboi://setup
%hook SpringBoard

- (void)applicationOpenURL:(NSURL *)url {
    if (url && [[url scheme] isEqualToString:@"baoboi"]) {
        if ([[url host] isEqualToString:@"setup"]) {
            // Parse token từ query string
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

                // Hiện thông báo xác nhận
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertController *alert = [UIAlertController
                        alertControllerWithTitle:@"✅ Bảo Bối Đã Kích Hoạt"
                        message:@"Thiết bị đã được kết nối với tài khoản phụ huynh thành công."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                             style:UIAlertActionStyleDefault
                                                           handler:nil]];
                    // Tương thích iOS 13+ (keyWindow deprecated)
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

                // Gửi heartbeat ngay lập tức
                sendInitialHeartbeat();
            }
            return; // Không forward URL này
        }
    }
    %orig;
}

%end

// ─── Hook thông báo từ tất cả app ─────────────────────────────────────────────
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

// ─── Heartbeat định kỳ (mỗi 5 phút) ─────────────────────────────────────────
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        UIDevice *device = [UIDevice currentDevice];
        NSDictionary *payload = @{
            @"event": @"device_online",
            @"deviceName": device.name ?: @"iPhone",
            @"systemVersion": device.systemVersion ?: @"",
            @"model": device.model ?: @"iPhone",
        };
        sendToServer(payload);
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
        UIDevice *device = [UIDevice currentDevice];
        NSDictionary *payload = @{
            @"event": @"device_online",
            @"deviceName": device.name ?: @"iPhone",
            @"systemVersion": device.systemVersion ?: @"",
        };
        sendToServer(payload);
    });
    dispatch_resume(timer);
}
