package App::Git::AutoCommit::Command;

use 5.014;
use strict;
use warnings;
use App::Cmd::Setup -command;

sub opt_spec {
    #<<<
    return (
        [ 'config|c=s' => 'location of your config file',
            { default => "$ENV{HOME}/.autocommit.conf" } ],
    );
    #>>>
}

sub get_config {
    my ( $self, $opt ) = @_;

    return $self->{config} if defined $self->{config};

    my $config_file = $opt->{config};
    unless ( $config_file and -r $config_file ) {
        $self->usage_error(
            "Unable to find or open the config file: " . $config_file );
    }

    # Merge the config file with the command line options
    return $self->{config} =
      { Config::General->new($config_file)->getall, %$opt, };
}

1;
