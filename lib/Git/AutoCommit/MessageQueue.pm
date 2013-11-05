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
use Promises qw( collect deferred );
use JSON;

has mq => ( is => 'ro', builder => 1, );
has channel => ( is => 'rw', );    # isa => 'AnyEvent::RabbitMQ::Channel', );
has exchange_delared => ( is => 'rw', isa => Bool, default => sub { 0 } );

has host     => ( is => 'ro', isa => Str, default => sub { 'localhost' } );
has port     => ( is => 'ro', isa => Int, default => sub { 5672 } );
has user     => ( is => 'ro', isa => Str, default => sub { 'guest' } );
has pass     => ( is => 'ro', isa => Str, default => sub { 'guest' } );
has vhost    => ( is => 'ro', isa => Str, default => sub { '/' } );
has exchange => ( is => 'ro', isa => Str, default => sub { 'test_exchange' } );

has id => ( is => 'ro', isa => Str, builder => 1, lazy => 1, );

# TODO: retry on failures

# To publish:
# Create AnyEvent::RabbitMQ
# Connect unless $mq->is_open
# Open Channel unless $channel && $channel->is_open
# Declare Exchange
# Publish

# To subscribe:
# Create AnyEvent::RabbitMQ
# Connect
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

# Publish and Consume: Connect, Open Channel and Create Exchange

sub connect {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] connecting to MQ");

    my $d = deferred;

    if ( not $self->mq->is_open ) {
        $self->mq->load_xml_spec->connect(
            host  => $self->host,
            port  => $self->port,
            user  => $self->user,
            pass  => $self->pass,
            vhost => $self->vhost,
            ## exhange    => 'foo',
            on_success => sub {
                $log->debugf("[GAMQ] connected");
                $d->resolve;
            },
            on_failure => sub {
                $log->warnf("[GAMQ] connect failed: %s", p @_);
                $d->reject;
            },
        );
    } else {
        $d->resolve;
    }

    return $d->promise;
}

sub open_channel {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] creating channel");

    my $d = deferred;

    if ( ! $self->channel or ! $self->channel->is_open ) {
        $self->mq->open_channel(
            on_success => sub {
                my $channel = shift;
                $log->debugf("[GAMQ] open_channel succeeded");
                $self->channel($channel);
                $d->resolve;
            },
            on_failure => sub {
                $log->warnf("[GAMQ] open_channel failed");
                die "Unable to open channel";
                $d->reject;
            },
            on_close => sub {
                my $method_frame = shift->method_frame;

                $log->warnf(
                    "[GAMQ] channel closed (%s): %s",
                    $method_frame->reply_code,
                    $method_frame->reply_text
                );

                $self->channel(undef);
                ## TODO: $d->?
            },
        );
    } else {
        $d->resolve;
    }

    return $d->promise;
}

sub declare_exchange {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] delaring exchange");

    my $d = deferred;

    if ( not $self->exchange_delared ) {

        $self->channel->declare_exchange(
            exchange   => $self->exchange,
            type       => 'topic',
            on_success => sub {
                $log->debugf("[GAMQ] declare_exchange succeeded");
                $self->exchange_delared(1);
                $d->resolve;
            },
            on_failure => sub {
                $log->warnf("[GAMQ] declare_exchange failed");
                die "Unable to declare exchange";
                $d->reject;
            },
        );
    } else {
        $d->resolve;
    }

    return $d->promise;
}

# Publish

sub _publish {
    my ( $self, $message, $topic ) = @_;

    my $json = JSON->new;
    my $msg = $json->encode( ref $message ? $message : [$message] );

    $log->debugf("[GAMQ] sending message: $msg");

    my $topic_str = sprintf "%s.%s", 'gamq', ( $topic // 'general' );

    $self->channel->publish(
        exchange    => $self->exchange,
        routing_key => $topic_str,
        header      => { headers => { publisher => $self->id } },
        body        => $msg,
    );
}

sub publish {
    my ( $self, $message, $topic ) = @_;

    #<<<
    collect(
        $self->connect
      )->then(
        sub { collect( $self->open_channel ) }
      )->then(
        sub { collect( $self->declare_exchange ) }
      )->then(
        sub { $self->_publish($message, $topic) }
      );
    #>>>
}

# Create Queue, Bind and Consume

sub declare_queue {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] building queue");

    my $d = deferred;

    $self->channel->declare_queue(
        ## exclusive => 1,
        ## exchange => $self->exchange,
        ## passive => 1,
        durable => 0,    # Would write messages to disk
        ## queue       => $args->{queue},
        auto_delete => 1,
        on_success  => sub {
            my $method = shift;
            my $queue  = $method->method_frame->queue;

            $log->debugf("[GAMQ] declare_queue succeeded: $queue");
            $d->resolve($queue);
        },
        on_failure => sub {
            $log->warnf("[GAMQ] declare_queue failed");
            die "Unable to open channel";
            $d->reject;

        },
    );

    return $d->promise;
}

sub bind_queue_to_exchange {
    my ( $self, $queue, $topic ) = @_;

    my $topic_str = sprintf "%s.%s", 'gamq', ( $topic // '#' );
    $log->debugf( "[GAMQ] binding queue %s to exchange (%s) w/ topic %s",
        $queue, $self->exchange, $topic_str );

    my $d = deferred;

    $self->channel->bind_queue(
        queue       => $queue,
        exchange    => $self->exchange,
        routing_key => $topic_str,
        on_success  => sub {
            $log->debugf("[GAMQ] bind_queue succeeded: $queue");
            $d->resolve( $queue );
        },
        on_failure => sub {
            $log->warnf("[GAMQ] bind_queue failed");
            die "Unable to bind_queue";
            $d->reject;
        },
    );

    return $d->promise;
}

sub _create_consumer {
    my ( $self, $queue, $args ) = @_;

    $self->channel->consume(
        queue  => $queue,
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

            if ( $args->{ignore_own} and $publisher eq $self->id ) {
                $log->debugf("[GAMQ] skipping msg from self");
            } else {
                $args->{cb}->($msg) if $args->{cb};
            }
        },
        on_success => sub {
            $log->debugf("[GAMQ] on_consume succeeded");
            $args->{on_success}->( $queue ) if $args->{on_success};
        },
        on_failure => sub {
            $log->warnf("[GAMQ] on_consume failed");
            $args->{on_failure}->( $queue ) if $args->{on_failure};
            die "Unable to open channel";
        },
        on_cancel => sub {
            $log->warnf("[GAMQ] on_consume cancelled");
            # TODO: try to resubscribe after a wait
        },
    );
}

sub subscribe {
    my ( $self, $args ) = @_;

    $log->debugf("[GAMQ] creating consumer");

    #<<<
    collect(
        $self->connect
      )->then(
        sub { collect( $self->open_channel ) }
      )->then(
        sub { collect( $self->declare_exchange ) }
      )->then(
        sub { collect( $self->declare_queue ) }
      )->then(
        sub {
            my $delcare_queue_rv = shift;
            my $queue = shift @$delcare_queue_rv;
            collect( $self->bind_queue_to_exchange( $queue, $args->{topic} ) );
          }
      )->then(
        sub {
            my $bind_queue_rv = shift;
            my $queue = shift @$bind_queue_rv;
            $self->_create_consumer( $queue, $args );
          }
      );
    #>>>
}

1;
