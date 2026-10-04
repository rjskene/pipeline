#!/bin/bash
# Cross-platform stand-in for GNU timeout.
# macOS does not ship `timeout`. Homebrew's coreutils names it gtimeout, and
# this machine may have neither. The perl fallback forks the command, sends
# the requested signal when the deadline hits, then SIGKILL after --kill-after.
set -euo pipefail

signal=TERM
kill_after=""
while [ $# -gt 0 ]; do
  case "$1" in
    --foreground) shift ;;
    --signal=*) signal="${1#--signal=}"; shift ;;
    --signal) signal="$2"; shift 2 ;;
    --kill-after=*) kill_after="${1#--kill-after=}"; shift ;;
    --kill-after) kill_after="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "portable-timeout: unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ $# -lt 2 ]; then
  echo "usage: portable-timeout [--foreground] [--signal=SIG] [--kill-after=SECS] SECS command..." >&2
  exit 2
fi

secs="$1"
shift

if command -v timeout >/dev/null 2>&1; then
  args=(--signal="$signal")
  [ -n "$kill_after" ] && args+=(--kill-after="$kill_after")
  exec timeout "${args[@]}" "$secs" "$@"
fi

if command -v gtimeout >/dev/null 2>&1; then
  args=(--signal="$signal")
  [ -n "$kill_after" ] && args+=(--kill-after="$kill_after")
  exec gtimeout "${args[@]}" "$secs" "$@"
fi

exec perl - "$secs" "$signal" "$kill_after" "$@" <<'PERL'
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

my $secs = shift @ARGV;
my $signal = shift @ARGV;
my $kill_after = shift @ARGV;
my @cmd = @ARGV;

my $pid = fork();
die "portable-timeout: fork: $!\n" unless defined $pid;
if ($pid == 0) {
    exec @cmd;
    exit 127;
}

sub reap_within {
    my ($limit) = @_;
    my $deadline = defined $limit ? time() + $limit : undef;
    while (1) {
        my $kid = waitpid($pid, WNOHANG);
        return 0 if $kid == $pid;
        return 1 if defined $deadline && time() >= $deadline;
        sleep(0.05);
    }
}

if (!reap_within($secs)) {
    my $status = $?;
    if ($status & 127) {
        exit 128 + ($status & 127);
    }
    exit($status >> 8);
}

kill $signal, $pid;
my $killed_hard = 0;
if (defined $kill_after && $kill_after ne '' && $kill_after > 0) {
    if (reap_within($kill_after)) {
        kill 'KILL', $pid;
        $killed_hard = 1;
        reap_within(undef);
    }
} else {
    reap_within(undef);
}

my $status = $?;
if ($killed_hard || (($status & 127) == 9)) {
    exit 137;
}
exit 124;
PERL
