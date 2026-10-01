import Foundation

/// What the transport buttons can ask the playing app to do.
enum NowPlayingCommand: String, CaseIterable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
}

/// A run of the helper: `/usr/bin/perl` with the driver script, the helper library and a mode.
///
/// The driver is a Swift string passed with `perl -e`, not a SwiftPM resource: there is no resource
/// bundle to find (or miss) in the installed plugin, and the script changes together with the
/// arguments built for it here.
struct HelperCommand: Equatable, Sendable {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    /// The helper library inside the plugin bundle; `build-plugin.sh` puts it there.
    static let libraryPath = "Contents/Helpers/libNowPlayingBridge.dylib"
    /// Exit status of a helper that cannot reach MediaRemote (`NOWPLAYING_EXIT_UNAVAILABLE`).
    static let unavailableStatus: Int32 = 69

    /// Loads the library given as the first argument with DynaLoader and calls the entry point for
    /// `stream` or `send <command>` (see NowPlayingBridge.h). The entry point never returns. When the
    /// library or the entry point cannot be loaded it prints the same `unavailable` line the library
    /// prints when MediaRemote cannot be loaded.
    static let driver = #"""
    use strict;
    use warnings;
    use DynaLoader;

    sub unavailable {
        my ($reason) = @_;
        $reason =~ s/[\x00-\x1f]/ /g;
        $reason =~ s/(["\\])/\\$1/g;
        print qq({"type":"unavailable","reason":"$reason"}\n);
        exit 69;
    }

    my ($library, @request) = @ARGV;
    my %entries = (stream => 'nowplaying_stream', map { ("send $_" => "nowplaying_send_$_") } qw(play pause toggle next previous));
    my $entry = defined $library ? $entries{join ' ', @request} : undef;
    defined $entry or do { print STDERR "usage: <library> stream | <library> send play|pause|toggle|next|previous\n"; exit 64 };
    my $handle = DynaLoader::dl_load_file($library, 0) or unavailable("cannot load $library: " . DynaLoader::dl_error());
    my $symbol = DynaLoader::dl_find_symbol($handle, $entry) or unavailable("$entry not found in $library");
    DynaLoader::dl_install_xsub('main::entry', $symbol);
    entry();
    """#

    let executable: URL
    let arguments: [String]

    /// Streams the Now Playing state as JSON lines until its stdin closes.
    static func stream(library: URL) -> HelperCommand {
        HelperCommand(executable: perl, arguments: ["-e", driver, "--", library.path, "stream"])
    }

    /// Sends one command and exits.
    static func send(_ command: NowPlayingCommand, library: URL) -> HelperCommand {
        HelperCommand(executable: perl, arguments: ["-e", driver, "--", library.path, "send", command.rawValue])
    }
}
