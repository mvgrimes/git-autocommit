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

has mq      => ( is => 'ro', builder => 1, );
has channel => ( is => 'rw' );
has exchange => ( is => 'ro', isa => Str, default => sub { 'test_exchange' } );
has _exchange_declared => ( is => 'rw', isa => Bool, default => sub { 0 } );
## has queue   => ( is => 'rw', );

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

sub _connect {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] connecting to MQ");

    $self->mq->load_xml_spec->connect(
        host       => 'localhost',
        port       => 5672,
        user       => 'guest',
        pass       => 'guest',
        vhost      => '/',
        exhange    => 'foo',
        on_success => sub {
            $log->debugf("client: connected");
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("client: connect failed");
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
            $log->debugf("client: open_channel succeeded");
            $self->channel($channel);
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("client: open_channel failed");
            die "Unable to open channel";
        },
        on_close => sub {
            my $method_frame = shift->method_frame;
            die $method_frame->reply_code, $method_frame->reply_text;
        },
    );

}

sub declare_exchange {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] delaring exchange");

    if ( $self->channel ) {
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
            $log->debugf("client: declare_exchange succeeded");
            $args->{cb}->() if $args->{cb};
        },
        on_failure => sub {
            $log->debugf("client: declare_exchange failed");
            die "Unable to declare exchange";
        },
    );
}

# sub _build_queue {
#     my ( $self, $args ) = @_;
#
#     $self->_declare_exchange;
#
#     $log->debugf("[GAMQ] building queue");
#
#     my $queue;
#     my $cv = AnyEvent->condvar;
#     $self->channel->declare_queue(
#         ## exclusive => 1,
#         ## exchange => $self->exchange,
#         ## passive => 1,
#         durable     => 0,                 # Would write messages to disk
#         queue       => 'my_queue_name',
#         auto_delete => 1,
#         on_success  => sub {
#             my $method = shift;
#             $queue = $method->method_frame->queue;
#             $log->debugf("[client] declare_queue succeeded: $queue");
#             $args->{cb}->() if $args->{cb};
#         },
#         on_failure => sub {
#             $log->debugf("client: declare_queue failed");
#             die "Unable to open channel";
#         },
#     );
#
#     return $queue;
# }
#
# sub create_consumer {
#     my ( $self, $args ) = @_;
#
#     $log->debugf("[GAMQ] creating consumer");
#
#     my $cv = AnyEvent->condvar;
#     $self->channel->consume(
#         queue  => $self->queue,
#         no_ack => 1,
#         ## consumer_tag => ,
#         on_consume => sub {
#             my ($frame) = @_;
#             my $body = $frame->{body}->payload;
#
#             # p $frame;
#             ## my $reply_to = $frame->{header}->reply_to;
#             my $topic = $frame->{deliver}->method_frame->routing_key;
#             ## return if $reply_to && $reply_to eq $self->_rf_queue;
#             $log->infof( "[client] topic is %s", $topic );
#
#             if ( $frame->{header}->headers->{publisher} eq
#                 sprintf( "%s.%s", hostname, $$ ) )
#             {
#                 $log->debugf("[client] skipping msg from self");
#             } else {
#                 my $json    = JSON->new();
#                 my $message = $json->decode($body)->{message};
#                 $log->debugf( "[client] receved msg: " . $message );
#             }
#         },
#         on_success => sub {
#             $log->debugf("[client] on_consume succeeded");
#             $args->{cb}->() if $args->{cb};
#         },
#         on_failure => sub {
#             $log->debugf("[client] on_consume failed");
#             die "Unable to open channel";
#         } );
# }
#
# sub bind_queue_to_exchange {
#     my ( $self, $args ) = @_;
#
#     $log->debugf("[GAMQ] binding queue to exchange");
#
#     my $cv = AnyEvent->condvar;
#     $self->channel->bind_queue(
#         queue       => $self->queue,
#         exchange    => $self->exchange,
#         routing_key => 'test.#',
#         on_success  => sub {
#             $log->debugf("[client] bind_queue succeeded");
#             $args->{cb}->() if $args->{cb};
#         },
#         on_failure => sub {
#             $log->debugf("[client] bind_queue failed");
#             $cv->send(0);
#         },
#     );
#     $cv->recv or die "Unable to open channel";
# }

sub publish {
    my ( $self, $message ) = @_;

    $log->debugf("[client] sending message: $message");

    # my $json = JSON->new;
    # my $body = $json->encode( { message => $i, } );

    if ( $self->_exchange_declared ) {
        $self->_publish($message);
    } else {
        $self->declare_exchange( {
                cb => sub {
                    $self->_exchange_declared(1);
                    $self->_publish($message);
                  }
            } );
    }
}

sub _publish {
    my ( $self, $message ) = @_;

    $self->channel->publish(
        exchange    => $self->exchange,
        routing_key => 'test.me',
        header => { headers => { publisher => sprintf "%s.%s", hostname, $$ } },
        body   => $message,
    );
}

# # Enter event loop
# $log->infof("[client] entering loop");
# AnyEvent->condvar->recv;

1;
