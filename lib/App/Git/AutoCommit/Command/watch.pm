package App::Git::AutoCommit::Command::watch;

# ABSTRACT: watch git repository for changes and auto commit

use 5.014;
use strict;
use warnings;
use mro;

use AnyEvent;
use AnyEvent::Filesys::Notify;
use App::Git::AutoCommit -command;
use Git::AutoCommit::FileWatcher;
use Git::AutoCommit::MessageQueue;
use Growl::Tiny;
use Config::General;
use Data::Printer;
use Log::Any qw($log);

# TODO: make sure only one watcher for each repo
# TODO: retry connection to MQ if they are dropped
# TODO: deal with merge conflicts
# TODO: add and commit all changes (add -A) on start (maybe after pull)

# sub usage_desc { "watch %o" }

# sub opt_spec {
#     my ($self) = @_;
#     #<<<
#     return (
#         ## []
#         $self->next::method,
#     );
#     #>>>
# }

# sub validate_args {
#     my ( $self, $opt, $args ) = @_;
# }

sub execute {
    my ( $self, $opt, $args ) = @_;

    my $config       = $self->get_config($opt);
    my $repositories = $config->{Repositories};
    die "No Repositories specified in config file\n"
      unless $repositories && ref $repositories eq "HASH";

    # Process the repositories specified on the command line or all in config
    my @repositories = @$args ? @$args : keys $repositories;

    my @watchers;
    for my $repo (@repositories) {
        $self->usage_error("Bad repository specified on command line: $repo")
          unless exists $repositories->{$repo};

        my $mq = Git::AutoCommit::MessageQueue->new();

        # Merge the global config with the Repository specific config
        my $repo_config = {
            %{ $config->{Global} // {} }, %{ $repositories->{$repo} },
            on_add    => sub { notify_of_event(shift) },
            on_rm     => sub { notify_of_event(shift) },
            on_commit => sub { notify_of_event(shift) },
            on_push   => sub {
                my $event = shift;
                notify_of_event($event);
                $mq->publish( $event, 'push' );
            },
        };

        $log->debugf( "[AGAW] '%s' watching path: %s",
            $repo, $repo_config->{path} );
        my $watcher = Git::AutoCommit::FileWatcher->new($repo_config);
        push @watchers, $watcher;

        my $cv = AnyEvent->condvar;
        $mq->subscribe( {
                ignore_own => 1,
                topic      => 'push',
                cb         => sub {
                    my $msg = shift;
                    $watcher->pull();
                    my $subject = sprintf "Pulling %s following: %s %s\n%s",
                      $watcher->path,
                      $msg->{repos},
                      $msg->{action},
                      ( exists $msg->{path} ? $msg->{path} : $msg->{message} );
                    notify( 'Git AutoCommit', $subject );
                },
                on_success => sub {
                    $log->debugf("[AGAW] subscribed to mq");
                    $cv->send(1);
                },
            } );
        $cv->recv or die;
    }

    # Enter event loop
    my $condvar = AnyEvent->condvar;
    $condvar->recv;
}

sub notify_of_event {
    my $event   = shift;
    no warnings 'uninitialized';
    my $subject = sprintf "Repository %s event: %s\n%s",
      $event->{repos},
      $event->{action},
      ( exists $event->{path} ? $event->{path} : $event->{message} );
    notify( 'Git AutoCommit', $subject );
}

sub notify {
    my ( $title, $subject ) = @_;

    Growl::Tiny::notify( {
        title    => $title,
        subject  => $subject,
        priority => 3,
        sticky   => 0,
        host     => 'localhost',
        ## image    => '/path/to/image.png',
    } );

}

1;
