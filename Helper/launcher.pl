use strict; use warnings; use DynaLoader;
my $lib = shift @ARGV or die "usage: launcher.pl <dylib>\n";
my $h = DynaLoader::dl_load_file($lib, 0) or die "cannot load $lib\n";
my $sym = DynaLoader::dl_find_symbol($h, "isle_run") or die "no symbol\n";
my $x = DynaLoader::dl_install_xsub("main::isle_run", $sym);
&$x();
