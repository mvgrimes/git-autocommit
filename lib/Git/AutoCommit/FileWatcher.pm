package Git::AutoCommit::FileWatcher;

use 5.014;
use strict;
use warnings;
use Moo;
use Type::Tiny;
use Types::Standard qw(ArrayRef Str Int Bool CodeRef);
use Data::Perl qw(array);
use Try::Tiny;
use Data::Dump qw(pp);
use Data::Printer;
use Log::Any qw($log);
use Sys::Hostname;
use Carp;
use Git::Wrapper;    # XXXX: Explore Git::Wrapper AnyEvent;

# TODO: Could use VCI::VCS to support non-git vcs

has path => ( is => 'ro', isa => Str, required => 1, );
has git => ( is => 'ro', builder => 1, lazy => 1, );

has file_watcher => ( is => 'ro', builder => 1, lazy => 1, );
has on_add       => ( is => 'ro', isa     => CodeRef, );
has on_rm        => ( is => 'ro', isa     => CodeRef, );

has commit_wait => ( is => 'ro', isa => Int, default => 5, );
has commit_timers   => ( is => 'ro', default => sub { array }, );
has commit_messages => ( is => 'ro', default => sub { array }, );
has on_commit       => ( is => 'ro', isa     => CodeRef, );

has pushable => ( is => 'ro', isa => Bool, builder => 1, lazy => 1, );
has push_wait => ( is => 'ro', isa => Int, default => 5, );
has push_timers => ( is => 'ro', default => sub { array }, );
has on_push => ( is => 'ro', isa => CodeRef, );
has on_pull => ( is => 'ro', isa => CodeRef, );

sub _build_file_watcher {
    my ($self) = @_;

    $log->debugf( "[GACW] '%s' creating AEFN", $self->path );
    return AnyEvent::Filesys::Notify->new(
        dirs   => [ $self->path ],
        cb     => sub { $self->on_filesys_change(@_) },
        filter => sub {
            shift !~ m{/\.git/};
            ## TODO: use .gitignore
        },
    );
}

sub _build_git {
    my ($self) = @_;

    $log->debugf( "[GACW] '%s' creating a Git::Wrapper", $self->path );
    return Git::Wrapper->new( $self->path );
}

sub _build_pushable {
    my ($self) = @_;

    my $remote_branches = $self->git->branch( { r => 1 } );
    return $remote_branches ? 1 : 0;
}

sub on_filesys_change {
    my ( $self, @events ) = @_;

    my $action_map = {
        created  => 'add',
        modified => 'add',
        deleted  => 'rm',
    };

    for my $event (@events) {
        $log->debugf( "[GACW] '%s' %s: %s",
            $self->path, $event->type, $event->path );

        my $action = $action_map->{ $event->type }
          or die "Unable to process event type: @{[ $event->type ]}";
        my $on_action = "on_$action";

        # Respond to action with git add/rm/etc
        $log->infof( "[GACW] '%s' git %s on %s",
            $self->path, $action, $event->path );
        $self->git->$action( $event->path );

        $self->$on_action->(
            { repos => $self->path, path => $event->path, action => $action } )
          if $self->$on_action;

        # Add a message to queue for the next commit
        my $msg = sprintf "%s %s", $event->type, $event->path;
        $self->commit_messages->push($msg);

        # Start count down timer to commit
        my $w = AnyEvent->timer(
            after => $self->commit_wait,
            cb    => sub { $self->do_commit } );
        $self->commit_timers->push($w);
    }
}

sub do_commit {
    my ($self) = @_;

    # Do nothing if there is no timer on the queue
    return unless $self->commit_timers->count > 0;

    # Get the next timer from the queue
    # XXXX: Assumes that this is the timer which initiated the callback
    my $w = $self->commit_timers->shift;

    # If there are other timers on the queue, then we haven't had a pause
    # in activity for commit_wait time yet.
    return if $self->commit_timers->count > 0;

    # Make sure the repos need committing
    if ( not $self->git->status->is_dirty ) {
        $log->infof( "[GACW] '%s' do_commit event but repos isn't dirty",
            $self->path );
        return;
    }

    # Do the commit
    $log->infof( "[GACW] '%s' git commit", $self->path );
    my $msg = sprintf( "AutoCommit on %s\n\n", hostname() )
      . join( "\n", $self->commit_messages->all );

    try {
        $self->git->commit( { message => $msg } );
        $self->on_commit->(
            { repos => $self->path, message => $msg, action => 'commit', } )
          if $self->on_commit;
    }
    catch {
        # TODO: What if conflict?
        # TODO: Resolve conflict
        # TODO: Push timer back on queue
        die p $_;
    };
    $self->commit_messages->clear;    # Empty the msg queue

    return unless $self->pushable;

    # Start a count down timer to push
    my $push_timer = AnyEvent->timer(
        after => $self->push_wait,
        cb    => sub { $self->do_push } );
    $self->push_timers->push($push_timer);
}

sub do_push {
    my ($self) = @_;

    # Do nothing if there is no timer on the queue
    return unless $self->push_timers->count > 0;

    # Get the next timer from the queue
    my $w = $self->push_timers->shift;

    # If there are other timers on the queue, then we haven't had a pause
    # in activity for push_wait time yet.
    return if $self->push_timers->count > 0;

    # Do the commit
    $log->infof( "[GACW] '%s' git push", $self->path );
    try {
        $self->git->push();
        $self->on_push->( { repos => $self->path, action => 'push', } )
          if $self->on_push;
    }
    catch {
        die p $_;
    };
}

sub pull {
    my ($self) = @_;

    # TODO: ignore changes while we pull
    croak "Cannot pull without origin" unless $self->pushable;
    $self->do_pull;
}

sub do_pull {
    my ($self) = @_;

    # Do the commit
    $log->infof( "[GACW] '%s' git pull", $self->path );
    try {
        $self->git->pull();
        $self->on_pull->( { repos => $self->path, action => 'pull', } )
          if $self->on_pull;
    }
    catch {
        die p $_;
    };
}

sub BUILD {
    my ($self) = @_;

    # Retrieve the file watcher to ensure it isn't too lazy
    my $watch = $self->file_watcher;
}

1;
