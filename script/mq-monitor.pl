#!/usr/bin/env perl

use 5.014;
use AnyEvent;
use AnyEvent::RabbitMQ;
use Data::Printer;
use Log::Any qw($log);
use Log::Any::Adapter;
use Sys::Hostname qw(hostname);
use JSON;
$|++;

Log::Any::Adapter->set( 'ScreenColoredLevel', min_level => 'debug' );
$log->debugf("client: model is $AnyEvent::MODEL");

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

my $cv = AnyEvent->condvar;
my $ar = AnyEvent::RabbitMQ->new;
$ar->load_xml_spec->connect(
    host       => 'localhost',
    port       => 5672,
    user       => 'guest',
    pass       => 'guest',
    vhost      => '/',
    exhange    => 'foo',
    on_success => sub {
        $log->debugf("client: connected");
        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("client: connect failed");
        $cv->send(0);
    },
);
$cv->recv or die "Unable to connect";

$cv = AnyEvent->condvar;
my $channel;
$ar->open_channel(
    on_success => sub {
        $channel = shift;
        $log->debugf("client: open_channel succeeded");
        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("client: open_channel failed");
        $cv->send(0);
    },
    on_close => sub {
        my $method_frame = shift->method_frame;
        die $method_frame->reply_code, $method_frame->reply_text;
    },
);
$cv->recv or die "Unable to open channel";

$cv = AnyEvent->condvar;
$channel->declare_exchange(
    exchange => 'test_exchange',
    type => 'topic',
    on_success => sub {
        $log->debugf("client: declare_exhcnage succeeded");
        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("client: declare_exchange failed");
        $cv->send(0);
    },
);
$cv->recv or die "Unable to open channel";

my $queue;
$cv = AnyEvent->condvar;
$channel->declare_queue(
    ## exclusive => 1,
    ## exchange => 'test_exchange',
    ## passive => 1,
    durable     => 0,                 # Would write messages to disk
    queue       => 'my_queue_name',
    auto_delete => 1,
    on_success  => sub {
        my $method = shift;
        $queue = $method->method_frame->queue;

        $log->debugf("[client] declare_queue succeeded");
        ## $log->debugf( p $method);
        $log->debugf( p $queue);

        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("client: declare_queue failed");
        $cv->send(0);
    },
);
$cv->recv or die "Unable to open channel";

$cv = AnyEvent->condvar;
$channel->consume(
    queue  => $queue,
    no_ack => 1,
    ## consumer_tag => ,
    on_consume => sub {
        my ($frame) = @_;

        ## p $frame;
        my $body = $frame->{body}->payload;

        ## my $reply_to = $frame->{header}->reply_to;
        ## my $topic    = $frame->{deliver}->method_frame->routing_key;
        ## $log->infof("[client] topic is %s", $topic);
        ## return if $reply_to && $reply_to eq $self->_rf_queue;

        if ( $frame->{header}->headers->{publisher} eq
            sprintf( "%s.%s", hostname, $$ ) )
        {
            $log->debugf("[client] skipping msg from self");
        } else {
            my $json = JSON->new();
            my $message = $json->decode( $body );
            $log->debugf( "[client] receved msg: " . p $message );
        }
    },
    on_success => sub {
        $log->debugf("[client] on_consume succeeded");
        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("[client] on_consume failed");
        $cv->send(0);
    } );
$cv->recv or die "Unable to open channel";

$cv = AnyEvent->condvar;
$channel->bind_queue(
    queue       => $queue,
    exchange    => 'test_exchange',
    routing_key => 'test.#',
    on_success  => sub {
        $log->debugf("[client] bind_queue succeeded");
        $cv->send(1);
    },
    on_failure => sub {
        $log->debugf("[client] bind_queue failed");
        $cv->send(0);
    },
);
$cv->recv or die "Unable to open channel";

# Enter event loop
$log->infof("[client] entering loop");
AnyEvent->condvar->recv;
