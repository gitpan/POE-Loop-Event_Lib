use strict;
use warnings;

use Test::More tests => 2;

BEGIN { use_ok 'Event::Lib' }

diag "Current method is '" . Event::Lib::get_method() . "' (You can control this via env vars...)";

eval "use POE qw(Loop::Event_Lib);";
is($@, "", 'Load POE with Loop::Event_Lib');
