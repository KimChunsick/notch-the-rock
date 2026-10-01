// The NowPlaying plugin's helper library. Recent macOS answers MediaRemote's Now Playing queries
// only for Apple's own processes, so the plugin starts /usr/bin/perl with a short driver script
// (`HelperCommand` in the plugin) that loads this library with DynaLoader, installs one entry point
// below as a perl sub and calls it. The library reaches MediaRemote with dlopen/dlsym at run time
// and links only Foundation.
//
// Every entry point has the shape perl calls an XSUB with, `(PerlInterpreter *, CV *)`, but never
// reads perl's stack and never returns: it does its work and ends the process. No argument crosses
// from perl, so the library needs no perl headers and works with any perl version.
#ifndef NOWPLAYING_BRIDGE_H
#define NOWPLAYING_BRIDGE_H

/// Exit status when MediaRemote or one of its functions cannot be loaded. A JSON line
/// `{"type":"unavailable","reason":...}` on stdout says so before the exit.
#define NOWPLAYING_EXIT_UNAVAILABLE 69

/// Writes one JSON object per line to stdout, the current state at once and then every change,
/// until stdin closes (exit status 0):
///
///     {"type":"none"}
///     {"type":"info","title":"…","artist":"…","album":"…","duration":231.4,"elapsed":12.0,
///      "timestamp":1790000000.5,"rate":1,"playing":true,"bundleID":"com.apple.Music",
///      "artwork":{"mime":"image/jpeg","data":"<base64>"}}
///
/// `none` means nothing is playing. In `info` only `type`, `title`, `timestamp` and `playing` are
/// always present; `elapsed` was sampled at `timestamp` (seconds since 1970). `artwork` is present
/// only when it changed since the previous line: an object with the new image, or null when the
/// image went away.
void nowplaying_stream(void *interpreter, void *cv) __attribute__((noreturn));

/// Send one command to the app that is playing. Exit status 0 when MediaRemote accepted the
/// command, 1 when it refused it.
void nowplaying_send_play(void *interpreter, void *cv) __attribute__((noreturn));
void nowplaying_send_pause(void *interpreter, void *cv) __attribute__((noreturn));
void nowplaying_send_toggle(void *interpreter, void *cv) __attribute__((noreturn));
void nowplaying_send_next(void *interpreter, void *cv) __attribute__((noreturn));
void nowplaying_send_previous(void *interpreter, void *cv) __attribute__((noreturn));

#endif
