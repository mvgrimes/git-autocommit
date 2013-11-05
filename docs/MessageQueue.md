# Summary of Message Queue options

## 0mq

- Pretty low level

### ZMQx::Class

- Non-blocking AnyEvent support
- Drops messages:
    - It's example scripts only get a small percentage
    - My test scripts with 2 second delays only get a small percentage

### AnyMQ::ZeroMQ

- Relies on AnyEvent::ZeroMQ which needs ZeroMQ::Raw
- Tied to zmq version 2
- CPAN module ZeroMQ::Raw fails to install

### ZeroMQ::PubSub

- Blocking

## Pusher.com

- Subscription service
- Believe based on websockets
- No client library on CPAN

## Firebase

- Subscription service
- Seems more like a value store, still not sure how to use as a queue
  (although I'm pretty sure it is possible)
- Have client library on CPAN, but looks like it blocks

## Firehose.io

- No subscription service (yet?)
- No CPAN clients
- Looks interesting

## Socket.io/Pocket.io

- Probably need to re-connect in clients
- Given our simple needs this is probably adequate, but otherwise this is
  pretty bare-bones
- CPAN modules

## RabbitMQ

- CPAN modules
- Opensource
- CloudAMQP provides as a service


## PubSubHubbub
