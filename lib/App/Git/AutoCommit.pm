package App::Git::AutoCommit;

use 5.014;
use strict;
use warnings;

use App::Cmd::Setup -app;
use Log::Any::Adapter;

Log::Any::Adapter->set( 'ScreenColoredLevel', min_level => 'debug' );

1;
