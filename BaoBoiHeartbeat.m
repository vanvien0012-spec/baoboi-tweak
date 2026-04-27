#import <Foundation/Foundation.h>

static NSString *const kServerURL = @"https://baoboidash.com/api/trpc/device.log";

static void sendHeartbeat(void) {
    // Đọc deviceToken từ file
    NSString *tokenPath = @"/var/mobile/Library/BaoBoiAgent/deviceToken.txt";
    NSString *deviceToken = [NSString stringWithContentsOfFile:tokenPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
    if (!deviceToken || deviceToken.length == 0) return;
    deviceToken = [deviceToken stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Lấy thông tin thiết bị
    NSString *deviceName = [[NSProcessInfo processInfo] hostName] ?: @"iPhone";
    NSString *iosVersion = [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"Unknown";

    NSDictionary *payload = @{
        @"json": @{
            @"event": @"heartbeat",
            @"deviceToken": deviceToken,
            @"deviceName": deviceName,
            @"iosVersion": iosVersion,
            @"batteryLevel": @(-1),
            @"isCharging": @(NO),
        }
    };

    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) return;

    NSURL *url = [NSURL URLWithString:kServerURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:30];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setHTTPBody:body];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) NSLog(@"[BaoBoiHeartbeat] Error: %@", err.localizedDescription);
        else NSLog(@"[BaoBoiHeartbeat] Heartbeat sent OK");
        dispatch_semaphore_signal(sema);
    }] resume];
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSLog(@"[BaoBoiHeartbeat] Started");
        
        // Gửi ngay lần đầu
        sendHeartbeat();
        
        // Lặp mỗi 5 phút
        while (YES) {
            [NSThread sleepForTimeInterval:5 * 60];
            sendHeartbeat();
        }
    }
    return 0;
}
