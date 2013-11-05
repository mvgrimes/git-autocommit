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
            on_commit => sub { $mq->publish( shift, 'commit' ) },
            on_push   => sub { $mq->publish( shift, 'push' ) },
            on_add    => sub { $mq->publish( shift, 'add' ) },
            on_rm     => sub { $mq->publish( shift, 'rm' ) },
        };

        $log->debugf( "[AGAW] '%s' watching path: %s",
            $repo, $repo_config->{path} );
        my $watcher = Git::AutoCommit::FileWatcher->new($repo_config);

        my $cv = AnyEvent->condvar;
        $mq->subscribe( {
                # TODO: needs include_only_own or just drop the MQ and use
                # notify directly
                cb => sub {
                    my $msg     = shift;
                    my $subject = sprintf "Repository %s event: %s\n%s",
                      $msg->{repos},
                      $msg->{action},
                      ( exists $msg->{path} ? $msg->{path} : $msg->{message} );
                    notify( 'Git AutoCommit', $subject );
                  },
                  on_success => sub {
                      $log->debugf("[AGAW] subscribed to repo 1");
                      $cv->send(1);
                  },
            } );
        $cv->recv or die;

        $mq->subscribe( {
                ignore_own => 1,
                topic => 'push',
                cb => sub {
                    # TODO: ignore changes while we pull
                    p @_;
                    my $msg     = shift;
                    $watcher->pull();
                    my $subject = sprintf "Pulling %s following: %s %s\n%s",
                      $watcher->path,
                      $msg->{repos},
                      $msg->{action},
                      ( exists $msg->{path} ? $msg->{path} : $msg->{message} );
                    notify( 'Git AutoCommit', $subject );
                  },
                  on_success => sub {
                      $log->debugf("[AGAW] subscribed to repo 2");
                  },
            } );

        push @watchers, $watcher;
    }

    # Enter event loop
    my $condvar = AnyEvent->condvar;
    $condvar->recv;
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
