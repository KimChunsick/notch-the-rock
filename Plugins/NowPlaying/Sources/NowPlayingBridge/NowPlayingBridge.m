#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "NowPlayingBridge.h"

#if !__has_feature(objc_arc)
#error "NowPlayingBridge is written for ARC"
#endif

static const char *const MediaRemotePath = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

/// Values of MediaRemote's `MRMediaRemoteCommand`.
enum {
    CommandPlay = 0,
    CommandPause = 1,
    CommandTogglePlayPause = 2,
    CommandNextTrack = 4,
    CommandPreviousTrack = 5,
};

enum { ExitRefused = 1 };

// MediaRemote's functions, resolved by name at run time.
static void (*GetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
static void (*GetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
static void (*RegisterForNotifications)(dispatch_queue_t);
static Boolean (*SendCommand)(int, CFDictionaryRef);
// Optional: the app that is playing. Web content reports the browser as its parent.
static void (*GetNowPlayingClient)(dispatch_queue_t, void (^)(CFTypeRef));
static CFStringRef (*ClientBundleIdentifier)(CFTypeRef);
static CFStringRef (*ClientParentBundleIdentifier)(CFTypeRef);

// MediaRemote's notification names and Now Playing info keys.
static NSString *InfoDidChange, *IsPlayingDidChange, *ApplicationDidChange;
static NSString *KeyTitle, *KeyArtist, *KeyAlbum, *KeyDuration, *KeyElapsed, *KeyTimestamp, *KeyRate;
static NSString *KeyArtworkData, *KeyArtworkMIME;

static void writeLine(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:NULL];
    if (data == nil) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void unavailable(NSString *reason) __attribute__((noreturn));
static void unavailable(NSString *reason) {
    writeLine(@{@"type": @"unavailable", @"reason": reason});
    exit(NOWPLAYING_EXIT_UNAVAILABLE);
}

static void *resolve(void *library, const char *name, NSMutableArray<NSString *> *missing) {
    void *symbol = dlsym(library, name);
    if (symbol == NULL) [missing addObject:@(name)];
    return symbol;
}

static NSString *resolveString(void *library, const char *name, NSMutableArray<NSString *> *missing) {
    CFStringRef *symbol = resolve(library, name, missing);
    return symbol == NULL ? nil : (__bridge NSString *)*symbol;
}

/// Resolves everything both modes use, or ends the process with the unavailable line.
static void loadMediaRemote(void) {
    void *library = dlopen(MediaRemotePath, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        unavailable([NSString stringWithFormat:@"cannot load MediaRemote: %s", dlerror()]);
    }
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    GetNowPlayingInfo = resolve(library, "MRMediaRemoteGetNowPlayingInfo", missing);
    GetIsPlaying = resolve(library, "MRMediaRemoteGetNowPlayingApplicationIsPlaying", missing);
    RegisterForNotifications = resolve(library, "MRMediaRemoteRegisterForNowPlayingNotifications", missing);
    SendCommand = resolve(library, "MRMediaRemoteSendCommand", missing);
    InfoDidChange = resolveString(library, "kMRMediaRemoteNowPlayingInfoDidChangeNotification", missing);
    IsPlayingDidChange = resolveString(library, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification", missing);
    ApplicationDidChange = resolveString(library, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification", missing);
    KeyTitle = resolveString(library, "kMRMediaRemoteNowPlayingInfoTitle", missing);
    KeyArtist = resolveString(library, "kMRMediaRemoteNowPlayingInfoArtist", missing);
    KeyAlbum = resolveString(library, "kMRMediaRemoteNowPlayingInfoAlbum", missing);
    KeyDuration = resolveString(library, "kMRMediaRemoteNowPlayingInfoDuration", missing);
    KeyElapsed = resolveString(library, "kMRMediaRemoteNowPlayingInfoElapsedTime", missing);
    KeyTimestamp = resolveString(library, "kMRMediaRemoteNowPlayingInfoTimestamp", missing);
    KeyRate = resolveString(library, "kMRMediaRemoteNowPlayingInfoPlaybackRate", missing);
    KeyArtworkData = resolveString(library, "kMRMediaRemoteNowPlayingInfoArtworkData", missing);
    KeyArtworkMIME = resolveString(library, "kMRMediaRemoteNowPlayingInfoArtworkMIMEType", missing);
    if (missing.count > 0) {
        unavailable([NSString stringWithFormat:@"MediaRemote lacks %@", [missing componentsJoinedByString:@", "]]);
    }
    GetNowPlayingClient = dlsym(library, "MRMediaRemoteGetNowPlayingClient");
    ClientBundleIdentifier = dlsym(library, "MRNowPlayingClientGetBundleIdentifier");
    ClientParentBundleIdentifier = dlsym(library, "MRNowPlayingClientGetParentAppBundleIdentifier");
}

static NSString *stringValue(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

// The ranges the plugin's reader takes (TrackInfo.secondsRange and rateRange in HelperLine.swift):
// up to a week for a length or position, -4...4 for a rate. A value outside is left out of the line.
static const double MaxSeconds = 604800, MaxRate = 4;

static void putNumber(NSMutableDictionary *line, NSString *key, id value, double min, double max) {
    if (![value isKindOfClass:NSNumber.class]) return;
    double number = [value doubleValue];
    if (isfinite(number) && number >= min && number <= max) line[key] = value;
}

static NSString *sourceBundleIdentifier(CFTypeRef client) {
    if (client == NULL || ClientBundleIdentifier == NULL) return nil;
    CFStringRef parent = ClientParentBundleIdentifier == NULL ? NULL : ClientParentBundleIdentifier(client);
    return stringValue((__bridge NSString *)(parent != NULL ? parent : ClientBundleIdentifier(client)));
}

// Stream state, touched on the main queue only.
static NSDictionary *lastLine;   // the last line written, without its artwork
static NSData *lastArtwork;      // the artwork the reader holds, nil for none
static uint64_t refreshesStarted, latestWritten;
static BOOL refreshScheduled;
static dispatch_source_t stdinSource;

/// Writes the state unless it repeats the previous line.
static void writeState(NSDictionary *info, BOOL playing, NSString *bundleIdentifier) {
    NSString *title = stringValue(info[KeyTitle]);
    if (title == nil) {
        lastArtwork = nil;
        NSDictionary *line = @{@"type": @"none"};
        if (![line isEqualToDictionary:lastLine]) writeLine(line);
        lastLine = line;
        return;
    }
    NSMutableDictionary *line = [NSMutableDictionary dictionaryWithDictionary:@{@"type": @"info", @"title": title}];
    if (stringValue(info[KeyArtist])) line[@"artist"] = info[KeyArtist];
    if (stringValue(info[KeyAlbum])) line[@"album"] = info[KeyAlbum];
    putNumber(line, @"duration", info[KeyDuration], 0, MaxSeconds);
    putNumber(line, @"elapsed", info[KeyElapsed], 0, MaxSeconds);
    putNumber(line, @"rate", info[KeyRate], -MaxRate, MaxRate);
    // The app's own sample time; without one, now is when the elapsed time was read.
    NSDate *sampled = [info[KeyTimestamp] isKindOfClass:NSDate.class] ? info[KeyTimestamp] : [NSDate date];
    line[@"timestamp"] = @(sampled.timeIntervalSince1970);
    line[@"playing"] = @(playing);
    if (bundleIdentifier) line[@"bundleID"] = bundleIdentifier;

    NSData *artwork = [info[KeyArtworkData] isKindOfClass:NSData.class] && [info[KeyArtworkData] length] > 0 ? info[KeyArtworkData] : nil;
    BOOL artworkChanged = artwork == nil ? lastArtwork != nil : ![artwork isEqualToData:lastArtwork];
    if (!artworkChanged && [line isEqualToDictionary:lastLine]) return;
    lastLine = [line copy];
    if (artworkChanged) {
        if (artwork == nil) {
            line[@"artwork"] = NSNull.null;
        } else {
            NSMutableDictionary *image = [NSMutableDictionary dictionaryWithObject:[artwork base64EncodedStringWithOptions:0] forKey:@"data"];
            if (stringValue(info[KeyArtworkMIME])) image[@"mime"] = info[KeyArtworkMIME];
            line[@"artwork"] = image;
        }
        lastArtwork = artwork;
    }
    writeLine(line);
}

/// Asks MediaRemote for the info, the playing flag and the source app, then writes the state. A
/// refresh that answers after a later one has written is dropped, so an older state never follows a
/// newer one.
static void refresh(void) {
    uint64_t number = ++refreshesStarted;
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block NSString *bundleIdentifier = nil;
    dispatch_group_enter(group);
    GetNowPlayingInfo(queue, ^(CFDictionaryRef dictionary) {
        info = (__bridge NSDictionary *)dictionary;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    GetIsPlaying(queue, ^(Boolean isPlaying) {
        playing = isPlaying != 0;
        dispatch_group_leave(group);
    });
    if (GetNowPlayingClient != NULL) {
        dispatch_group_enter(group);
        GetNowPlayingClient(queue, ^(CFTypeRef client) {
            bundleIdentifier = sourceBundleIdentifier(client);
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, queue, ^{
        if (number < latestWritten) return;
        latestWritten = number;
        @autoreleasepool {
            writeState(info, playing, bundleIdentifier);
        }
    });
}

/// MediaRemote posts several notifications for one change; they become one refresh.
static void scheduleRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (refreshScheduled) return;
        refreshScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            refreshScheduled = NO;
            refresh();
        });
    });
}

/// The plugin holds the other end of stdin; when it closes it, or dies, the helper ends.
static void exitWhenStdinCloses(void) {
    stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(stdinSource, ^{
        char buffer[256];
        ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
            fflush(stdout);
            exit(0);
        }
    });
    dispatch_resume(stdinSource);
}

void nowplaying_stream(void *interpreter, void *cv) {
    @autoreleasepool {
        loadMediaRemote();
        RegisterForNotifications(dispatch_get_main_queue());
        for (NSString *name in @[InfoDidChange, IsPlayingDidChange, ApplicationDidChange]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                scheduleRefresh();
            }];
        }
        exitWhenStdinCloses();
        refresh();
    }
    CFRunLoopRun();
    exit(0);
}

/// Sends `command`, then waits for one more answer from MediaRemote (at most a second) before
/// exiting: the command travels asynchronously, and exiting at once could drop it.
static void send(int command) __attribute__((noreturn));
static void send(int command) {
    @autoreleasepool {
        loadMediaRemote();
    }
    int status = SendCommand(command, NULL) ? 0 : ExitRefused;
    GetIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
        exit(status);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        exit(status);
    });
    CFRunLoopRun();
    exit(status);
}

void nowplaying_send_play(void *interpreter, void *cv) { send(CommandPlay); }
void nowplaying_send_pause(void *interpreter, void *cv) { send(CommandPause); }
void nowplaying_send_toggle(void *interpreter, void *cv) { send(CommandTogglePlayPause); }
void nowplaying_send_next(void *interpreter, void *cv) { send(CommandNextTrack); }
void nowplaying_send_previous(void *interpreter, void *cv) { send(CommandPreviousTrack); }
