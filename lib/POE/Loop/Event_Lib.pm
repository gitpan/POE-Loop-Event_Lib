# Event_Lib.pm event loop bridge for POE::Kernel.

# This started out as a copy of POE::Loop::Event.

# Empty package to appease perl.
package POE::Loop::Event_Lib;

use strict;

use vars qw($VERSION);
$VERSION = '0.001_01';

# Everything plugs into POE::Kernel.
package # hide me from PAUSE
  POE::Kernel;

use strict;
use Config;
use POE::Kernel;
use Event::Lib;

# Global map of signal names<->numbers
my %sig_name2num;
my @sig_num2name;

# Global list of Event::Lib signal objects, indexed by signal number
my @signal_events;

# Global Event::Lib timer object
my $_watcher_timer;

# Global list of Event::Lib filehandle objects, indexed by fd number
my @fileno_watcher;

############################################################################
# Initialization, Finalization, and the Loop itself
############################################################################


{
  # Map the signal names<->numbers
  defined $Config{sig_name} || die "No sigs?";

  my $i = 0;
  foreach my $name (split(' ', $Config{sig_name})) {
    $sig_name2num{$name} = $i;
    $sig_num2name[$i] = $name;
    $i++;
  }
}

sub loop_initialize {
  my $self = shift;

  # Set up the global timer object;
  $_watcher_timer = timer_new(\&_loop_timer_callback);
  $SIG{'PIPE'} = 'IGNORE';
}

sub loop_finalize {
  my $self = shift;

  foreach my $fd (0..$#fileno_watcher) {
    next unless defined $fileno_watcher[$fd];
    foreach my $mode (EV_READ, EV_WRITE) {
      POE::Kernel::_warn(
        "Mode $mode watcher for fileno $fd is defined during loop finalize"
      ) if defined $fileno_watcher[$fd]->[$mode];
    }
  }

  $self->loop_ignore_all_signals();
}

sub loop_attach_uidestroy {
  # does nothing, no UI
}

sub loop_do_timeslice { event_one_loop() }

sub loop_run {
  my $self = shift;
  while ($self->_data_ses_count()) {
    event_one_loop();
  }
}

sub loop_halt {
  $_watcher_timer->remove() if $_watcher_timer->pending();
  undef $_watcher_timer;
}

############################################################################
# Signal Handling
############################################################################

sub loop_watch_signal {
  my ($self, $signame) = @_;

  return if $signame eq 'KILL'; # Nonsensical, and not supported by libevent

  # Child process has stopped.
  if ($signame eq 'CHLD' or $signame eq 'CLD') {
    # We should never twiddle $SIG{CH?LD} under poe, unless we want to override
    # system() and friends. --hachi
    #    $SIG{$signame} = "DEFAULT";
    $self->_data_sig_begin_polling();
    return;
  }

  my $signum = $sig_name2num{$signame};

  # Optimize away re-watch of already watched thing.
  if(defined $signal_events[$signum]) {
    $signal_events[$signum]->add() unless $signal_events[$signum]->pending();
    return;
  }

  my $new_ev = signal_new($signum, \&_loop_signal_callback, $signame);
  $signal_events[$signum] = $new_ev;
  $new_ev->add();

  return;
}

sub loop_ignore_signal {
  my ($self, $signame) = @_;

  if ($signame eq 'CHLD' or $signame eq 'CLD') {
    $self->_data_sig_cease_polling();
    # We should never twiddle $SIG{CH?LD} under poe, unless we want to override
    # system() and friends. --hachi
    #    $SIG{$signame} = "IGNORE";
    return;
  }

  my $signum = $sig_name2num{$signame};

  if(defined $signal_events[$signum]) {
    $signal_events[$signum]->remove();
  }

  if($signame eq 'PIPE') {
      $SIG{'PIPE'} = 'IGNORE';
  }
}

sub loop_ignore_all_signals {
  my $self = shift;

  map { $_->remove if defined $_ } @signal_events;
  @signal_events = ();
  $SIG{'PIPE'} = 'IGNORE';
}

sub _loop_signal_callback {
  if (TRACE_SIGNALS) {
    my $pipelike = $_[2] eq 'PIPE' ? 'PIPE-like' : 'generic';
    POE::Kernel::_warn "<sg> Enqueuing $pipelike SIG$_[2] event";
  }

  $poe_kernel->_data_ev_enqueue(
    $poe_kernel, $poe_kernel, EN_SIGNAL, ET_SIGNAL, [ $_[2] ],
    __FILE__, __LINE__, undef, time()
  );
}

############################################################################
# Timer code
############################################################################

sub loop_resume_time_watcher {
  my ($self, $next_time) = @_;
  ($_watcher_timer and $next_time) or return;

  my $seconds = $next_time - time();
  $seconds = 0.00001 if $seconds <= 0; # 0 == indefinite for libevent

  $_watcher_timer->remove() if $_watcher_timer->pending();
  $_watcher_timer->add($seconds);
}

sub loop_reset_time_watcher {
  my ($self, $next_time) = @_;
  ($_watcher_timer and $next_time) or return;

  my $seconds = $next_time - time();
  $seconds = 0.00001 if $seconds <= 0; # 0 == indefinite for libevent

  $_watcher_timer->remove() if $_watcher_timer->pending();
  $_watcher_timer->add($seconds);
}

sub loop_pause_time_watcher {
  $_watcher_timer or return;
  $_watcher_timer->remove() if $_watcher_timer->pending();
}

# Timer callback to dispatch events.
my $last_time = time();
sub _loop_timer_callback {
  my $self = $poe_kernel;

  if (TRACE_STATISTICS) {
    # TODO - I'm pretty sure the startup time will count as an unfair
    # amount of idleness.
    #
    # TODO - Introducing many new time() syscalls.  Bleah.
    $self->_data_stat_add('idle_seconds', time() - $last_time);
  }

  $self->_data_ev_dispatch_due();
  $self->_test_if_kernel_is_idle();

  # Transferring control back to Event; this is idle time.
  $last_time = time() if TRACE_STATISTICS;
}

############################################################################
# Filehandle code
############################################################################

# helper function, not a method
sub _mode_to_evlib {
  return EV_READ if $_[0] == MODE_RD;
  return EV_WRITE if $_[0] == MODE_WR;

  confess "POE::Loop::Event_Lib does not support MODE_EX"
    if $_[0] == MODE_EX;

  confess "Unknown mode $_[0]";
}

sub loop_watch_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);
  my $evlib_mode = _mode_to_evlib($mode);

  my $event = $fileno_watcher[$fileno]->[$evlib_mode];

  if(defined $event) {
    $event->remove if $event->pending();
    undef $fileno_watcher[$fileno]->[$evlib_mode];
  }

  my $new_obj = event_new(
    $handle,
    $evlib_mode | EV_PERSIST,
    \&_loop_select_callback
  );

  $fileno_watcher[$fileno]->[$evlib_mode] = $new_obj;
  $new_obj->add();
}

sub loop_ignore_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);
  my $evlib_mode = _mode_to_evlib($mode);
  my $event = $fileno_watcher[$fileno]->[$evlib_mode];

  return if !defined $event;

  $event->remove if $event->pending;
  undef $fileno_watcher[$fileno]->[$evlib_mode];
}

sub loop_pause_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);
  my $evlib_mode = _mode_to_evlib($mode);
  my $event = $fileno_watcher[$fileno]->[$evlib_mode];

  $event->remove() if $event->pending();
}

sub loop_resume_filehandle {
  my ($self, $handle, $mode) = @_;

  my $fileno = fileno($handle);
  my $evlib_mode = _mode_to_evlib($mode);
  my $event = $fileno_watcher[$fileno]->[$evlib_mode];

  $event->add() if !$event->pending();
}

# Event filehandle callback to dispatch selects.
sub _loop_select_callback {
  my $self = $poe_kernel;

  my ($event, $evlib_mode) = @_;

  my $mode = ($evlib_mode == EV_READ)
    ? MODE_RD
    : ($evlib_mode == EV_WRITE)
      ? MODE_WR
      : confess "Invalid mode occured in POE::Loop::Event_Lib: $evlib_mode";

  $self->_data_handle_enqueue_ready($mode, fileno($event->fh));
  $self->_test_if_kernel_is_idle();
}

1;

__END__

=head1 NAME

POE::Loop::Event_Lib - a bridge that supports Event::Lib from POE

=head1 SYNOPSIS

See L<POE::Loop>.

=head1 BROKEN / IN DEVELOPMENT

There's a reason for the underscore in the version number.  This
software is definitely broken at the moment, so don't even think
about using it anywhere that needs to not be broken.

All of my testing is against the latest L<POE>, L<Event::Lib>,
L<POE::Test::Loops>, and libevent (1.3d).

Currently, on MacOS X, it passes the test suite if you use the
C<EVENT_*> env vars to limit it to either the C<select>, or
C<poll> method, but it still fails one test with C<kqueue> (but
then again, libevent's own regression tests fail with C<kqueue>
on this box/environment, so I'm not sure this is my fault).

On Linux (recent 2.6-based distro), it passes all tests under
C<select>, but has some isolated failures under both C<poll>
and C<epoll>.

I think it's fair to assume something is actually incorrect either
in this code (more likely), L<Event::Lib> (less likely), or
libevent (really unlikely).  It's possible this is related to some
impedance mismatch between the libevent and POE models that I
haven't fully grokked yet.

I've also just installed it anyways and tried an actual complicated
POE-based daemon of mine against it on the Mac.  The app actually
runs successfully in most cases, even with C<kqueue>, so long
as I run the app in debug mode (no daemonization via doublefork/setsid,
and all logging straight to stderr).  When I turn on daemonization
and logging, things get stuck very early on.

YMMV, I'm mainly putting this out here hoping someone else will
find the problems faster than me and send a patch :)

=head1 DESCRIPTION

This class is an implementation of the abstract POE::Loop interface.
It follows POE::Loop's public interface exactly.  Therefore, please
see L<POE::Loop> for its documentation.

L<Event::Lib> is a Perl abstraction of C<libevent>, which supports
the following underlying mechanisms on different platforms:
C<select>, C<poll>, C<devpoll>, C<epoll>, and C<kqueue>.

By default, it will select the best available mechanism.  You can
disable certain mechanisms from being selected via the environment
variables C<EVENT_NOPOLL>, C<EVENT_NOSELECT>, C<EVENT_NOEPOLL>,
C<EVENT_NODEVPOLL>, and C<EVENT_NOKQUEUE>.  These environment
variables must be set before C<use>-ing L<POE::Loop::Event_Lib>.

Of note, not all underlying mechanisms support operations on
regular physical files (some only support things like sockets
and pipes).  See the L<Event::Lib> documentation for more
information.

=head1 SEE ALSO

L<POE>, L<POE::Loop>, L<Event::Lib>

=head1 AUTHOR

Brandon L. Black <blblack@gmail.com>

=head1 LICENSE

POE::Loop::Event_Lib is free software;
you may redistribute it and/or modify it under the same terms as Perl itself.

=head1 IGNORE ME

This is for some automated test generation stuff...

=for poe_tests

sub skip_tests {
  return "Event::Lib tests require the Event::Lib module" if (
    do { eval "use Event::Lib"; $@ }
  );

  my $test_name = shift;
  if ($^O eq 'darwin' and Event::Lib::get_method() ne 'select') {
    if($test_name eq "wheel_readline" or $test_name eq "wheel_run") {
      return "This test only works with the Event::Lib 'select' method on $^O";
    }
  }
}

=cut
