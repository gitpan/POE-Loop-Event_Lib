
use inc::Module::Install 0.65;

name           'POE-Loop-Event_Lib';
all_from       'lib/POE/Loop/Event_Lib.pm';

# I think this is the only way to specify POE::Test::Loops
test_requires 'POE::Test::DondeEstan'     => 0;

test_requires 'Test::More'  => '0.47';
requires 'POE'              => '0.9999';
requires 'Event::Lib'       => '1.03';

############# Copied from POE's Makefile.PL

unless (-t STDIN) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "Assuming --default because standard input is not a terminal.\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
  push @ARGV, "--default";
}

# Remind the user she can use --default.

unless (grep /^--default$/, @ARGV) {
  warn(
    "\n",
    "====================================================================\n",
    "\n",
    "Prompts may be bypassed by running:\n",
    "   $^X $0 --default\n",
    "\n",
    "====================================================================\n",
    "\n",
  );
}

# Should we skip the network tests?

my $prompt = qq|
Some of POE's tests require a functional network.
You can skip these tests if you'd like.

Would you like to skip the network tests?|;

my $ret = "n";
if (grep /^--default$/, @ARGV) {
  print $prompt, " [n] n\n\n";
}
else {
  $ret = prompt($prompt, "n");
}

my $marker = 'run_network_tests';

if($ret =~ /^Y$/i) {
    unlink $marker if $marker;
} else {
    open(TOUCH,"+>$marker") and close TOUCH;
}

print "\n";

############# End copied stuff

system("poe-gen-tests", "--dirbase", "t/30_loops", "--loop", "Event::Lib")
  and die $!;

tests "t/*.t t/*/*/*.t";

# Rebuild README for maintainers
if(-e 'MANIFEST.SKIP') {
  system("pod2text lib/POE/Loop/Event_Lib.pm > README");
}

auto_provides;
auto_install;
WriteAll;
