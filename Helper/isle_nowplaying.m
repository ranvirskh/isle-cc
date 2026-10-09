// Isle's system Now Playing helper (original code). Loaded into /usr/bin/perl by a tiny launcher script,
// because on recent macOS only Apple-signed processes may call MediaRemote. Prints one JSON object per line
// on stdout; reads one command per line on stdin. Never links MediaRemote: everything is dlsym'd, so a missing
// symbol yields {"supported":false,...} instead of a crash.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (^InfoBlock)(CFDictionaryRef);
typedef void (^BoolBlock)(Boolean);
typedef void (^ClientBlock)(id);
static void (*MRGetInfo)(dispatch_queue_t, InfoBlock);
static void (*MRGetPlaying)(dispatch_queue_t, BoolBlock);
static void (*MRGetClient)(dispatch_queue_t, ClientBlock);
static void (*MRRegister)(dispatch_queue_t);
static Boolean (*MRSend)(int, CFDictionaryRef);
static CFStringRef (*MRClientBundle)(id);
static CFStringRef (*MRClientParent)(id);
static void (*MRSetElapsed)(double);

static dispatch_queue_t Q;
static NSString *lastLine = @"";
static NSString *lastArtID = @"";

static void emit(NSDictionary *d) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static id str(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static id num(id v) { return [v isKindOfClass:NSNumber.class] ? v : nil; }

static void publish(void) {
    dispatch_group_t g = dispatch_group_create();
    __block NSDictionary *info = nil; __block BOOL playing = NO; __block NSString *bundle = @"", *parent = @"";
    dispatch_group_enter(g);
    MRGetInfo(Q, ^(CFDictionaryRef d) { info = d ? [(__bridge NSDictionary *)d copy] : nil; dispatch_group_leave(g); });
    dispatch_group_enter(g);
    MRGetPlaying(Q, ^(Boolean p) { playing = p; dispatch_group_leave(g); });
    dispatch_group_enter(g);
    MRGetClient(Q, ^(id c) {
        if (c) {
            if (MRClientBundle) bundle = (__bridge NSString *)MRClientBundle(c) ?: @"";
            if (MRClientParent) parent = (__bridge NSString *)MRClientParent(c) ?: @"";
        }
        dispatch_group_leave(g);
    });
    dispatch_group_notify(g, Q, ^{
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        if (!info || !str(info[@"kMRMediaRemoteNowPlayingInfoTitle"])) { o[@"empty"] = @YES; o[@"playing"] = @(playing); }
        else {
            o[@"playing"] = @(playing);
            o[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            o[@"artist"] = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]) ?: @"";
            o[@"album"] = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]) ?: @"";
            if (num(info[@"kMRMediaRemoteNowPlayingInfoDuration"])) o[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
            if (num(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) o[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
            if (num(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) o[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([ts isKindOfClass:NSDate.class]) o[@"timestamp"] = @([(NSDate *)ts timeIntervalSince1970]);
            id ex = num(info[@"kMRMediaRemoteNowPlayingInfoIsExplicitContent"]) ?: num(info[@"kMRMediaRemoteNowPlayingInfoExplicit"]);
            if (ex) o[@"explicit"] = ex;
            id cid = str(info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]);
            if (cid) o[@"id"] = cid;
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:NSData.class] && art.length) {
                // Only resend artwork when it changed (it can be large).
                NSString *aid = [NSString stringWithFormat:@"%lu-%@", (unsigned long)art.length, o[@"title"]];
                o[@"artworkID"] = aid;
                if (![aid isEqualToString:lastArtID]) { o[@"artwork"] = [art base64EncodedStringWithOptions:0]; lastArtID = aid; }
            }
        }
        o[@"bundle"] = bundle; o[@"parent"] = parent;
        NSMutableDictionary *cmp = [o mutableCopy]; [cmp removeObjectForKey:@"timestamp"];
        emit(o);
    });
}

static void command(NSString *line) {
    NSArray *p = [line componentsSeparatedByString:@" "];
    NSString *c = p.firstObject;
    int cmd = -1;
    if ([c isEqualToString:@"play"]) cmd = 0;
    else if ([c isEqualToString:@"pause"]) cmd = 1;
    else if ([c isEqualToString:@"toggle"]) cmd = 2;
    else if ([c isEqualToString:@"next"]) cmd = 4;
    else if ([c isEqualToString:@"previous"]) cmd = 5;
    else if ([c isEqualToString:@"shuffle"]) cmd = 26;
    else if ([c isEqualToString:@"seek"] && p.count > 1) {
        double s = [p[1] doubleValue];
        if (MRSetElapsed) MRSetElapsed(s);
        if (MRSend) MRSend(45, (__bridge CFDictionaryRef)@{@"kMRMediaRemoteOptionPlaybackPosition": @(s)});
        return;
    }
    if (cmd >= 0 && MRSend) MRSend(cmd, NULL);
}

void bootstrap_Isle(void) {}

__attribute__((visibility("default")))
void isle_run(void) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(@{@"supported": @NO, @"error": @"MediaRemote not loadable"}); return; }
        MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRGetPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        MRRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRSend = dlsym(h, "MRMediaRemoteSendCommand");
        MRClientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
        MRClientParent = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
        MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
        if (!MRGetInfo || !MRGetPlaying || !MRGetClient || !MRRegister) {
            emit(@{@"supported": @NO, @"error": @"MediaRemote symbols missing"}); return;
        }
        Q = dispatch_queue_create("isle.nowplaying", DISPATCH_QUEUE_SERIAL);
        MRRegister(Q);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *x) { publish(); }];
        }
        emit(@{@"supported": @YES});
        publish();
        // Commands arrive on stdin.
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, 0, 0, dispatch_get_main_queue());
        __block NSMutableString *buf = [NSMutableString string];
        dispatch_source_set_event_handler(src, ^{
            char tmp[512]; ssize_t n = read(0, tmp, sizeof tmp);
            if (n <= 0) { exit(0); }   // parent went away
            [buf appendString:[[NSString alloc] initWithBytes:tmp length:n encoding:NSUTF8StringEncoding] ?: @""];
            NSRange r;
            while ((r = [buf rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [buf substringToIndex:r.location];
                [buf deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
                if ([line isEqualToString:@"poll"]) publish(); else command(line);
            }
        });
        dispatch_resume(src);
        [[NSRunLoop mainRunLoop] run];
    }
}
