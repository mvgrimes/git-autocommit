requires 'perl', '5.014';

requires 'App::Cmd', '0.32';
requires 'AnyEvent';
requires 'AnyEvent::Filesys::Notify';
requires 'Data::Dump';
requires 'IPC::Cmd';
requires 'Git::Wrapper' , '0.030';
requires 'Sys::Hostname';
requires 'Try::Tiny';

requires 'Moo',           '1.001';
requires 'MooX::late',    '0.014';
requires 'Data::Perl',    '0.002007';
requires 'FindBin::libs', '0';
requires 'Type::Tiny';
requires 'Types::Standard',                       '0.001';
requires 'Log::Any',                              '0.15';
requires 'Log::Any::Adapter',                     '0.11';
requires 'Log::Any::Adapter::ScreenColoredLevel', '0.04';
requires 'Config::General',                       '2.52';
requires 'Growl::Tiny',                       '0.0.4';

# requires 'Path::Class',   '0.32';
# requires 'DBD::SQLite',                '0';
# requires 'namespace::autoclean',       '0';
# requires 'autovivification',           '0';
# requires 'DateTime',                   '1.03';
# requires 'DateTime::Format::Strptime', '1.54';

on test => sub {
    requires 'Test::Class',       '0.39';
    requires 'Test::Differences', '0.61';
    requires 'Test::Most',        '0.31';

    # requires 'Test::Number::Delta',        '0';
};
