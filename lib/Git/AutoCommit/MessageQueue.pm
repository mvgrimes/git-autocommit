package Git::AutoCommit::MessageQueue;

use 5.014;
use strict;
use warnings;
use Moo;
use Type::Tiny;
use Types::Standard qw(ArrayRef Str Int Bool CodeRef);
use Try::Tiny;
use Data::Dump qw(pp);
use Data::Printer;
use Log::Any qw($log);
use Sys::Hostname;
use AnyEvent::RabbitMQ;
use JSON;

has mq => ( is => 'ro', builder => 1, );
has channel => ( is => 'rw', );    # isa => 'AnyEvent::RabbitMQ::Channel', );
has queue => ( is => 'rw', isa => Str );

# has queue_name => ( is => 'rw', isa => Str, buider => 1 );

has host     => ( is => 'ro', isa => Str, default => sub { 'localhost' } );
has port     => ( is => 'ro', isa => Int, default => sub { 5672 } );
has user     => ( is => 'ro', isa => Str, default => sub { 'guest' } );
has pass     => ( is => 'ro', isa => Str, default => sub { 'guest' } );
has vhost    => ( is => 'ro', isa => Str, default => sub { '/' } );
has exchange => ( is => 'ro', isa => Str, default => sub { 'test_exchange' } );

has id => ( is => 'ro', isa => Str, builder => 1, lazy => 1, );

# To publish:
# Create AnyEvent::RabbitMQ
# Open Channel
# Declare Exchange
# Publish

# To subscribe:
# Create AnyEvent::RabbitMQ
# Open Channel
# Declare Exchange
# Declare Queue
# Bind Queue to Exchange
# Create Consumer

sub _build_mq {
    my ($self) = @_;

    $log->debugf("[GAMQ] creating AnyEvent::RabbitmQ");
    return AnyEvent::RabbitMQ->new;
}

sub _build_id {
    my ($self) = @_;
    sprintf( "%s.%s", hostname, $$ );
}

# sub _build_queue_name {
#     my ($self) = @_;
#
#     return sprintf "%s.%s.%s", hostname, $$, int(rand(10_000));
# }

# Publish and Consume: Connect, Open Channel and Create Exchange

sub _connect {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] connecting to MQ");

    $self->mq->load_xml_spec->connect(
        host  => $self->host,
        port  => $self->port,
        user  => $self->user,
        pass  => $self->pass,
        vhost => $self->vhost,
        ## exhange    => 'foo',
        on_success => sub {
            $log->debugf("[GAMQ] connected");
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("[GAMQ] connect failed");
            die "Unable to connect";
        },
    );
}

sub open_channel {
    my ( $self, $args ) = @_;

    if ( $self->mq->is_open ) {
        $self->_open_channel($args);
    } else {
        $self->_connect( {
                cb => sub {
                    $self->_open_channel($args);
                  }
            } );

    }
}

sub _open_channel {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] creating channel");

    $self->mq->open_channel(
        on_success => sub {
            my $channel = shift;
            $log->debugf("[GAMQ] open_channel succeeded");
            $self->channel($channel);
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("[GAMQ] open_channel failed");
            die "Unable to open channel";
        },
        on_close => sub {
            my $method_frame = shift->method_frame;
            $log->warnf( "[GAMQ] channel closed (%s): %s",
                $method_frame->reply_code, $method_frame->reply_text );

            $self->channel(undef);
            $self->queue(undef);

            # $self->clear_channel;
            # $self->clear_queue;
        },
    );

}

sub declare_exchange {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] delaring exchange");

    if ( $self->channel && $self->channel->is_open ) {
        $self->_declare_exchange($args);
    } else {
        $self->open_channel( {
                cb => sub {
                    $self->_declare_exchange($args);
                  }
            } );
    }
}

sub _declare_exchange {
    my ( $self, $args ) = @_;

    $self->channel->declare_exchange(
        exchange   => $self->exchange,
        type       => 'topic',
        on_success => sub {
            $log->debugf("[GAMQ] declare_exchange succeeded");
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("[GAMQ] declare_exchange failed");
            die "Unable to declare exchange";
        },
    );
}

# Publish

sub publish {
    my ( $self, $message ) = @_;

    my $json = JSON->new;
    my $msg = $json->encode( ref $message ? $message : [$message] );

    $log->debugf("[GAMQ] sending message: $msg");

    if ( $self->channel && $self->channel->is_open ) {
        $self->_publish($msg);
    } else {
        $self->declare_exchange( {
                cb => sub {
                    $self->_publish($msg);
                  }
            } );
    }
}

sub _publish {
    my ( $self, $message, $topic ) = @_;

    my $topic_str = sprintf "%s.%s", 'gamq', ( $topic // 'general' );

    $self->channel->publish(
        exchange    => $self->exchange,
        routing_key => $topic_str,
        header      => { headers => { publisher => $self->id } },
        body        => $message,
    );
}

# Create Queue, Bind and Consume

sub declare_queue {
    my ( $self, $args ) = @_;

    if ( $self->channel && $self->channel->is_opn ) {
        $self->_declare_queue($args);
    } else {
        $self->declare_exchange( {
                cb => sub {
                    $self->_declare_queue($args);
                  }
            } );
    }
}

sub _declare_queue {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] building queue");

    $self->channel->declare_queue(
        ## exclusive => 1,
        ## exchange => $self->exchange,
        ## passive => 1,
        durable => 0,    # Would write messages to disk
        ## queue       => $self->queue_name,
        auto_delete => 1,
        on_success  => sub {
            my $method = shift;
            my $queue  = $method->method_frame->queue;
            $log->debugf("[GAMQ] declare_queue succeeded: $queue");
            $self->queue($queue);

            # queue must always be bound, so let the bind method call the
            # original cb if/when successful

            $self->bind_queue_to_exchange($args);
        },
        on_failure => sub {
            $log->debugf("[GAMQ] declare_queue failed");
            die "Unable to open channel";
        },
    );
}

sub bind_queue_to_exchange {
    my ( $self, $args ) = @_;

    my $topic_str = sprintf "%s.%s", 'gamq', ( $args->{topic} // '#' );
    $log->debugf( "[GAMQ] binding queue to exchange (%s) w/ topic %s",
        $self->exchange, $topic_str );

    $self->channel->bind_queue(
        queue       => $self->queue,
        exchange    => $self->exchange,
        routing_key => $topic_str,
        on_success  => sub {
            $log->debugf("[GAMQ] bind_queue succeeded");
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("[GAMQ] bind_queue failed");
            die "Unable to bind_queue";
        },
    );
}

sub subscribe {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] creating consumer");

    if ( $self->queue ) {
        $self->_create_consumer($args);
    } else {
        $self->declare_queue( {
                cb => sub {
                    $self->_create_consumer($args);
                  }
            } );
    }
}

sub _create_consumer {
    my ( $self, $args ) = @_;

    $self->channel->consume(
        queue  => $self->queue,
        no_ack => 1,
        ## consumer_tag => ,
        on_consume => sub {
            my ($frame) = @_;
            my $body = $frame->{body}->payload;

            $log->debugf( "[GAMQ] receved msg: " . $body );

            my $json = JSON->new;
            my $msg  = $json->decode($body);

            ## p $frame;
            ## my $reply_to = $frame->{header}->reply_to;
            ## return if $reply_to && $reply_to eq $self->_rf_queue;
            my $topic = $frame->{deliver}->method_frame->routing_key;
            $log->infof( "[GAMQ] topic is %s", $topic );
            my $publisher = $frame->{header}->headers->{publisher};

            if ( $publisher eq $self->id ) {
                $log->debugf("[GAMQ] skipping msg from self");
                $args->{cb}->($msg) if $args->{cb}; # XXXX: testing
            } else {
                $args->{cb}->($msg) if $args->{cb};
            }
        },
        on_success => sub {
            $log->debugf("[GAMQ] on_consume succeeded");
        },
        on_failure => sub {
            $log->debugf("[GAMQ] on_consume failed");
            die "Unable to open channel";
        } );
}

1;
