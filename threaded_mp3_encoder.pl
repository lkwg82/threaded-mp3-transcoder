#! /usr/bin/perl

$| = 1;

use strict;
use warnings;
use Data::Dumper;

use File::Basename;
use File::Copy;
use File::Find;
use File::Path;
use File::Temp qw/ tempfile/;

use Proc::NiceSleep qw( :all );

use threads;
use Thread;
use Thread::Queue;
use  Unix::Process;

use Time::HiRes qw( usleep ualarm gettimeofday tv_interval nanosleep
  clock_gettime clock_getres clock_nanosleep clock
  stat );

my $threads = {
	'lister' => 0,
	'worker' => []
};

my $listing : shared          = new Thread::Queue;
my $listing_complete : shared = 0;
our %running : shared;

my %thread_limits : shared = (
	'total'           => 8,
	'encoding'        => 2,     # number = cpu cores + 1
	'copying'         => 0,     #
	'wait_for_copy'   => '1',
	'wait_for_encode' => '1',
	'priority'        => 0
);


our $CONFIG = {
	'source_dir' => '',
	'dest_dir'   => '',
	'overwrite' => 0,                 # 0|1
	'threads'   => \%thread_limits,
	'debug'    => 1,                  # 0|1 increase logging
	'lame_bin' => 'lame',
	'lame_par' => join(
		' ',
		(
			'-p',    # error protection.  adds 16 bit checksum to every frame
			         # (the checksum is computed correctly)
			'--vbr-new',  # use new variable bitrate (VBR) routine
			'-b 32',      # specify minimum allowed bitrate, default  32 kbps
			'-B 320',     # specify maximum allowed bitrate, default 320 kbps
			'--silent',   # don't print anything on screen
			'-m j',       # (j)oint, (s)imple, (f)orce, (d)dual-mono, (m)ono
			              # default is (j) or (s) depending on bitrate
			              # joint  = joins the best possible of MS and LR stereo
			              # simple = force LR stereo on all frames
			              # force  = force MS stereo on all frames.
			              #'--mp3input',

		)
	)
};

if ( scalar(@ARGV) == 2 ){
	map{
		unless( /^\// ){
			my $path=`pwd`;
			chomp($path);
			$_ = $path.'/'.$_;
		}
	}@ARGV;
}
else{
  print "\ncall misses some arguments\n";
	print "call $0 <source directory> <destination directory>\n";
	exit 1;
}

if ( &ask_for_paths( @ARGV ) ) {
	$CONFIG->{'source_dir'} = $ARGV[0];
	$CONFIG->{'dest_dir'} = $ARGV[1];
}
else{
	exit;
}


# Argumente verarbeiten
die "source dir does not exist \"" . $CONFIG->{'source_dir'} . "\" \n" unless ( -d $CONFIG->{'source_dir'} );

if ( $ARGV[0] ne $ARGV[1] ) {
  $CONFIG->{'source_dir'} = $ARGV[0];
  $CONFIG->{'dest_dir'}   = $ARGV[1];
}
else {
  die "klappt nicht";
}

&mkdir( $CONFIG->{'dest_dir'} ) unless ( -d $CONFIG->{'dest_dir'} );

{
	# create a thread to create listing of source dir
	$threads->{'lister'} =
	  Thread->new( \&create_listing, ( $CONFIG->{'source_dir'}, \$listing ) );

	$threads->{'lister'}->join();
	$listing_complete = 1;
};

$threads->{'status'} =
  Thread->new( \&status, ( \%running, \$listing, \%thread_limits ) );

sleep(1);

foreach ( 1 .. $CONFIG->{'threads'}->{'total'} ) {
	push(
		@{ $threads->{'workers'} },
		Thread->new( \&do_it, ( \$listing, \$listing_complete, \%running ) )
	);
}

grep { $_->join(); } @{ $threads->{'workers'} };

$threads->{'status'}->join();

#~ $threads->{'summary'} = Thread->new( \&show_summary, ($CONFIG) );
#~ $threads->{'summary'}->join();

sub ask_for_paths{
	my ($source,$dest) = @_;

	use Gtk2::Ex::Dialogs::Question ( destroy_with_parent => 1,
                                          modal => 1,
                                          no_separator => 0 );

	my $r = ask Gtk2::Ex::Dialogs::Question ( "Should I convert all from \n $source \n to \n $dest ?" );

	return $r;
}

sub show_summary {
	my $ref = shift || die "need ref to running\n";

	our $stats;
	our $current_dir;

	sub dir_props {
		$File::Find::dont_use_nlink = 1;

		#print $File::Find::dir, " ", $File::Find::name, "\n";

		( my $item = $File::Find::name ) =~ s/^$current_dir//;

		push( @{ $stats->{$current_dir}{'list'} }, $item );

		if ( -d $File::Find::name ) {
			$stats->{$current_dir}{'dirs'} += 1;
		}
		elsif ( -f $File::Find::name ) {
			$stats->{$current_dir}{'files'} += 1;
			$stats->{$current_dir}{'size'}  += ( -s $File::Find::name );
		}
		else {
			print "unknown type $item \n";

		}
	}

	sub format {
		my $number = shift;
		$number = reverse($number);
		print $number, "\n";
		$number =~ s/(\d{3})/$1\./g;

		#print $number,"\n";

		$number = reverse($number);

		#print $number,"\n";

		$number =~ s/^\.//;

		return $number;
	}

	grep {
		$current_dir = $ref->{ $_ . '_dir' };
		find( { wanted => \&dir_props, follow => 1, no_chdir => 0 },
			$current_dir );

		print "$current_dir:", $stats->{$current_dir}{'files'}, "\n";
	} qw/source dest/;

	#print Data::Dumper::Dumper($stats);

	my $diff = &array_diff(
		$stats->{ $ref->{'dest_dir'} }->{'list'},
		$stats->{ $ref->{'source_dir'} }->{'list'}
	);

	my $diff_text;

	$diff_text = "left: " + $diff->{'left'} + "\n" ;
	$diff_text .= "right: " + $diff->{'right'} + "\n" ;

	$diff_text .= " added [ \n";
	grep{ $diff_text .=  "  ".$_."\n"; }@{$diff->{'added'}};
	$diff_text .= "] \n";


	$diff_text .= " deleted [ \n";
	grep{ $diff_text .=  "  ".$_."\n"; }@{$diff->{'deleted'}};
	$diff_text .= "] \n";

	use Gtk2 '-init';
	use Gtk2 qw/-init -threads-init 1.050/;

	die "Glib::Object thread safetly failed"
	  unless Glib::Object->set_threadsafe(1);

	my $window2 = Gtk2::Window->new;
	$window2->set_title('finished');
	$window2->set_default_size( 600, 300 );

	$window2->signal_connect( delete_event => sub { Gtk2->main_quit; 1 } );

	my $label_test = Gtk2::Label->new();
	my $button_ok  = Gtk2::Button->new('beenden');

	$label_test->set_text(
		    $ref->{'source_dir'} . "\n"
		  . $ref->{'dest_dir'} . "\n"
		  . sprintf( "%s\n", "-" x 50 )
		  . sprintf("%s   %s \n",	"dirs",
			(
				$stats->{ $ref->{'source_dir'} }{'dirs'} == $stats->{ $ref->{'dest_dir'} }{'dirs'}
			  ) ?
				"equal (" . $stats->{ $ref->{'source_dir'} }{'dirs'} . ")" :
				$stats->{ $ref->{'source_dir'} }{'dirs'} . ":" . $stats->{ $ref->{'dest_dir'} }{'dirs'}
		  )
		  . sprintf(
			"%s   %s \n",
			"files",
			(
				$stats->{ $ref->{'source_dir'} }{'files'} ==  $stats->{ $ref->{'dest_dir'} }{'files'}
			  ) ? "equal ("
			  . $stats->{ $ref->{'source_dir'} }{'files'} . ")"
			: $stats->{ $ref->{'source_dir'} }{'files'} . ":"
			  . $stats->{ $ref->{'dest_dir'} }{'files'}
		  )
		  . sprintf(
			"%s   %5s - %5s \n",
			"size",
			&format( $stats->{ $ref->{'source_dir'} }{'size'} ),
			&format( $stats->{ $ref->{'dest_dir'} }{'size'} )
		  )
		  . "\n"
		  . sprintf(
			"%s   reducted to %.2f%% \n",
			"benefit",
			$stats->{ $ref->{'dest_dir'} }{'size'} / 			  $stats->{ $ref->{'source_dir'} }{'size'} * 100
		  )."\n".$diff_text
	);

	$button_ok->signal_connect( pressed => sub { Gtk2->main_quit; 1 } );

	my $pane = Gtk2::VPaned->new;
	$pane->set_position(50);
	$window2->add($pane);


	$pane->add($button_ok);
	$pane->add($label_test);

	# all in one go
	$window2->show_all;

	#print Dumper($diff);

	print "total:",scalar( @{$stats->{ $ref->{'source_dir'} }->{'list'}}),"\n";
	Gtk2->main;
	exit 0;
}

# --------------------------------------------------------------------------------------------------------------------
# number of threads in state running
# return int
sub threads_running {
	my $running_ref = shift || die "need ref to running\n";
	return &threads_status( $running_ref, 'r' );
}

# --------------------------------------------------------------------------------------------------------------------
# number of threads in state copying
# return int
sub threads_copying {
	my $running_ref = shift || die "need ref to running\n";
	return &threads_status( $running_ref, 'c' );
}

# --------------------------------------------------------------------------------------------------------------------
# number of threads in state encoding
# return int
sub threads_encoding {
	my $running_ref = shift || die "need ref to running\n";
	return &threads_status( $running_ref, 'e' );
}

# --------------------------------------------------------------------------------------------------------------------
# number of threads in state #2
# return int
sub threads_status {
	my $running_ref = shift || die "need ref to running\n";
	my $status      = shift || die "which status ?\n";

	my $n = 0;

	lock($running_ref);

	grep { $n += ( (/^$status/) ? 1 : 0 ); } ( values %{$running_ref} );

	return $n;
}

# --------------------------------------------------------------------------------------------------------------------
# set state of thread
# void
sub thread_setStatus {
	my $running_ref = shift || die "need ref to running\n";
	my $status      = shift || die "no status given \n";

	{
		lock($running_ref);
		$running_ref->{ Thread->self->tid } = $status;
	}
	&log_debug( $running_ref->{ Thread->self->tid } );
}

# --------------------------------------------------------------------------------------------------------------------
# logging
# void
sub log_debug : locked {
	my $text = shift || die "need text to output \n";

	print "(", Thread->self->tid, ") ", $text, "\n" if ( $CONFIG->{'debug'} );
}

# --------------------------------------------------------------------------------------------------------------------
# do_the_job
# void
sub do_it {
	my $list_ref    = shift || die "need a list to enqueue to\n";
	my $complete    = shift || die "dont know whether listing is complete \n";
	my $running_ref = shift || die "need running data hash \n";

	my $tid = Thread->self->tid;
	my $finished;    # when list empty and listing_complete

	&thread_setStatus( $running_ref, "s:starting" );

	while ( !$finished ) {
		if ( $$list_ref->pending == 0 ) {
			if ($$complete) {
				$finished = 1;
				&thread_setStatus( $running_ref, 'f:finished' );

				#print "($tid) - shutting down, no more work \n";
			}
			else {
				&thread_setStatus( $running_ref, 'w:waiting for listing' );
				sleep(1);
			}
		}
		else {
			my $file;
			{
				lock $running_ref;
				$file = $$list_ref->dequeue();
				log_debug("running: " . $$list_ref->pending() . " left - $file \n" );
			}

			die("processing $file failed\n") unless ( &copy_reencode_copy( $running_ref, \$file ) );
		}
	}
}

# --------------------------------------------------------------------------------------------------------------------
# wait for free slot and then do action
# return boolean
sub thread_wait {
	my $running     = shift || die "need running data hash \n";
	my $status      = shift || die "need status \n";
	my $status_next = shift || die "need status next\n";
	my $job_ref     = shift || die "need ref for job \n";
	my $job_args    = shift || die "need args for job \n";

	die "need to be a code reference " unless ( ref($job_ref) eq 'CODE' );

	my $limit;
	my $current;
	my $sleep;

	my $job_done;
	my $result;

	while ( !$job_done ) {

		if ( $status =~ /^e/ ) {
			$limit   = $CONFIG->{'threads'}->{'encoding'};
			$sleep   = $CONFIG->{'threads'}->{'wait_for_encode'};
			$current = \&threads_encoding;
		}
		elsif ( $status =~ /^c/ ) {
			$limit   = $CONFIG->{'threads'}->{'copying'};
			$sleep   = $CONFIG->{'threads'}->{'wait_for_copy'};
			$current = \&threads_copying;
		}

		if ( $limit > $current->($running) ) {
			&thread_setStatus( $running, $status );
			$result = $job_ref->( @{$job_args} );
			&thread_setStatus( $running, $status_next );
			$job_done = 1;
		}
		else {
			sleep($sleep);
		}
	}

	return $result;
}

# --------------------------------------------------------------------------------------------------------------------
# copy from src, reencode and copy to dest
# return boolean
sub copy_reencode_copy {
	my $running = shift || die "need running data hash \n";
	my $src     = shift || die "need file to process \n";

	my $result;
	( my $dest = $$src ) =~ s/^$CONFIG->{'source_dir'}/$CONFIG->{'dest_dir'}/o;

	if ( !$CONFIG->{'overwrite'} && ( -e $dest ) ) {
		log_debug('file already existing');
		return 1;
	}

	if ( -d $$src ) {
		$result = 1;
	}
	else {
		&mkdir( dirname($dest) );
		if ( $$src !~ /\.mp3$/i ) {
			$result = &thread_wait(
				$running,
				"c:copying non-mp3 $$src",
				"w:waiting for next job",
				\&copy_and_check, [ $$src, $dest ]
			);
		}
		else {
			my $tempfile_src  = new File::Temp( UNLINK => 0, SUFFIX => '.mp3' );
			my $tempfile_dest = new File::Temp( UNLINK => 0, SUFFIX => '.mp3' );

			$result = &thread_wait(
				$running,
				"c:copying from $$src",
				"w:waiting for encoding",
				\&copy_and_check, [ $$src, $tempfile_src ]
			);

			log_debug('copying failed') unless ($result);
			return $result              unless ($result);    # return on error

			$result = &thread_wait(
				$running,
				"e:encoding $$src",
				"w:waiting for copying back",
				\&encode, [ $tempfile_src, $tempfile_dest ]
			);

			log_debug('encoding failed') unless ($result);
			return $result               unless ($result);    # return on error

			$result = &thread_wait(
				$running,
				"c:copying to $dest",
				"w:waiting for next job",
				\&copy_and_check, [ $tempfile_dest, $dest ]
			);

			log_debug('copying failed') unless ($result);
			unlink($tempfile_src)  || die "could not delete $tempfile_src \n $^E \n";
			unlink($tempfile_dest) || die "could not delete $tempfile_dest \n $^E \n";
		}
	}

	return $result;
}

# --------------------------------------------------------------------------------------------------------------------
# create recursivly the listing of #1
# void
sub create_listing {
	my $dir  = shift || die "no directory given\n";
	my $list = shift || die "need a list to enqueue to\n";

	my $list_complete_ref = shift || -1;

	$File::Find::dont_use_nlink = 1;

	find(
		sub {
			my $path = $File::Find::name;

			${$list}->enqueue($File::Find::name);
		},
		($dir)
	);

	unless ( $list_complete_ref == -1 ) {
		lock($$list_complete_ref);
		$$list_complete_ref = 1;
	}
}

# --------------------------------------------------------------------------------------------------------------------
# create recursivly the directory #1
# void
sub mkdir {
	my $dir = shift || die "no directory given\n";
	eval { mkpath($dir) };
	if ($@) {
		die "Couldn't create $dir: $@";
	}
}

# --------------------------------------------------------------------------------------------------------------------
# encode from #1 to #2 [ and try #3 times to re-encode on failure]
# return boolean
sub encode {
	my $source = shift || die "no source given\n";
	my $dest   = shift || die "no destination given \n";
	my $eLimit = shift || 3;    # do not try more than ... to re-encode
	my $eCount = 0;
	my $success;

	do {
		my $cmd =
		    $CONFIG->{'lame_bin'} . " "
		  . $CONFIG->{'lame_par'}
		  . " $source $dest";

		if ( $^O =~ /linux/ ) {
			$cmd = "nice -n " . $thread_limits{'priority'} . " $cmd ";
		}

		$success = `$cmd && echo 1 || echo 0`;

	} until ( ( $eCount++ == $eLimit ) || $success );

	return ( $eCount <= $eLimit );
}

# --------------------------------------------------------------------------------------------------------------------
# copy from #1 to #2 [ and try #3 times to copy on failure]
# return boolean
sub copy_and_check {
	my $source = shift || die "no source given\n";
	my $dest   = shift || die "no destination given \n";
	my $eLimit = shift || 3;    # do not try more than ... to copy

	my $sizes = sub {
		die "no source and destination file given \n" if ( scalar(@_) != 2 );
		return [ ( -s $_[0] ), ( ( -e $_[1] ) ? ( -s $_[1] ) : 0 ) ];
	};

	#~ my $mask = sub {
	#~ ${$_[0]} =~ s/([\ \(\)\'\]\[])/\\$1/g;
	#~ };

	#~ $mask->( \$source );
	#~ $mask->( \$dest );

	my $eCount = 0;
	my ( $sizeSource, $sizeDest ) = @{ $sizes->( $source, $dest ) };
	my $tmp_dest = "$dest.uncomplete";

	do {

		#~ log_debug("----------------------------------------------");
		#~ log_debug("copy file $source --> $tmp_dest ");
		copy( $source, $tmp_dest )
		  || die "error while copying: $source --> $tmp_dest \n $^E \n";

		#~ log_debug("source   : ".(-s $source ));
		#~ log_debug("$tmp_dest : ".(-s $tmp_dest ));

		( $sizeSource, $sizeDest ) = @{ $sizes->( $source, $tmp_dest ) };

#~ print $sizeSource," = ",$sizeDest," : ",( $sizeDest == $sizeSource ? 'equal' : 'mismatch'),"\n";
	} until ( ( $eCount++ == $eLimit ) || ( $sizeSource == $sizeDest ) );

	#~ log_debug("renaming file $tmp_dest --> $dest");
	move( $tmp_dest, $dest )
	  || die "error while renaming: $tmp_dest --> $dest \n $^E \n";

	#~ log_debug("$dest : ".(-s $dest ));
	#~ print `ls -l $dest`;
	#~ log_debug("existiert? : ".(-e $dest));
	#~ log_debug("$dest : ".(-f $dest ));
	#~ log_debug("$dest : ".(-s $dest ));
	#~ exit;
	#~ log_debug( ($eCount <= $eLimit) ? 'kaum Fehler' : 'zuviele Fehler');

	return ( ( $eCount <= $eLimit ) && ( $sizeSource == $sizeDest ) );
}

sub status {
	our $running_ref   = shift || die "need ref to running\n";
	our $list_ref      = shift || die "need a list \n";
	our $thread_limits = shift || die "need limits \n";

	our $max = $$list_ref->pending;

	use Gtk2 '-init';
	use Gtk2 qw/-init -threads-init 1.050/;
	use Gtk2::SimpleList;

	use constant TRUE  => 1;
	use constant FALSE => 0;

	die "Glib::Object thread safetly failed"
	  unless Glib::Object->set_threadsafe(TRUE);

	my $window = Gtk2::Window->new;
	$window->set_title( 'threads overview - ' . $CONFIG->{'source_dir'} );
	$window->signal_connect(
		delete_event => sub {

			#&show_summary($CONFIG);
			Gtk2->main_quit;
			TRUE;
		}
	);
	$window->set_default_size( 1600, 500 );

	my $pane = Gtk2::VPaned->new;
	$window->add($pane);

	our $slist = Gtk2::SimpleList->new(
		'thread ID' => 'int',
		'status'    => 'text',
		'test'      => 'text',
	);

	our $progress = Gtk2::ProgressBar->new;
	$progress->set_fraction(0);

	# (almost) anything you can do to an array you can do to
	# $slist->{data} which is an array reference tied to the list model
	#~ push @{$slist->{data}}, [ 1,'text', 4 ];

	# Gtk2::SimpleList is derived from Gtk2::TreeView, so you can
	# do anything you'd do to a treeview.
	$slist->set_rules_hint(TRUE);
	$slist->set_reorderable(TRUE);
	map { $_->set_resizable(TRUE) } $slist->get_columns;

	# packed into a scrolled window...
	my $scrolled = Gtk2::ScrolledWindow->new;
	$scrolled->set_policy( 'automatic', 'automatic' );
	$scrolled->add($slist);
	$pane->add($progress);

	my $pane_bottom = Gtk2::VPaned->new;

	$pane->add($pane_bottom);

	my $hbox = Gtk2::HBox->new;
	$pane_bottom->add($hbox);

	my $label_enc    = Gtk2::Label->new('encoder');
	my $spin_encoder =
	  Gtk2::SpinButton->new_with_range( 0, $thread_limits->{'total'}, 1 );
	$spin_encoder->set_value( $thread_limits->{'encoding'} );
	$spin_encoder->signal_connect(
		value_changed => \&on_spinbutton_encoder_value_changed );

	$hbox->add($label_enc);
	$hbox->add($spin_encoder);

	my $label_copyier = Gtk2::Label->new('copier');
	my $spin_copyier  = Gtk2::SpinButton->new_with_range( 0, $thread_limits->{'total'}, 1 );
	$spin_copyier->set_value( $thread_limits->{'copying'} );
	$spin_copyier->signal_connect(value_changed => \&on_spinbutton_copyier_value_changed );

	$hbox->add($label_copyier);
	$hbox->add($spin_copyier);

	$spin_copyier->set_value( $thread_limits->{'copying'} );

	my $label_prio = Gtk2::Label->new('priority');
	my $spin_prio = Gtk2::SpinButton->new_with_range( 0, 20, 1 );
	$spin_prio->set_value( $thread_limits->{'priority'} );
	$spin_prio->signal_connect(value_changed => \&on_spinbutton_prio_value_changed );

	if ( $^O =~ /linux/ ) {
		$hbox->add($label_prio);
		$hbox->add($spin_prio);
	}

	#	my $label_threads = Gtk2::Label->new('threads');
	#	my $spin_threads = Gtk2::SpinButton->new_with_range( 0, 20, 1 );
	#	$spin_threads->set_value( $thread_limits->{'total'} );
	#	$spin_threads->signal_connect(
	#		value_changed => \&on_spinbutton_threads_value_changed );
	#
	#	$hbox->add($label_threads);
	#	$hbox->add($spin_threads);

	#	$spin_threads->set_value( $thread_limits->{'total'} );

	$pane_bottom->add($scrolled);

	sub on_spinbutton_threads_value_changed {

		#~ print $_[0]->get_value,"\n";
		#~ lock($thread_limits);
		#~ $thread_limits->{'total'} = $_[0]->get_value;
	}

	sub on_spinbutton_prio_value_changed {
		$thread_limits->{'priority'} = $_[0]->get_value;

	}

	sub on_spinbutton_copyier_value_changed {

		#~ print $_[0]->get_value,"\n";
		lock($thread_limits);
		$thread_limits->{'copying'} = $_[0]->get_value;
	}

	sub on_spinbutton_encoder_value_changed {

		#~ print $_[0]->get_value,"\n";
		lock($thread_limits);
		$thread_limits->{'encoding'} = $_[0]->get_value;
	}

	sub _worker_ {

		grep { push( @{ $slist->{data} }, [ 0, undef, undef ] ); } 1 .. $CONFIG->{'threads'}->{'total'};
		my @keys;

		while (1) {
			@keys = sort keys %{$running_ref};
			Gtk2::Gdk::Threads->enter;

			for ( my $i = 0 ; $i < scalar(@keys) ; $i++ ) {
				my ( $status, $text ) =
				  split( /:/, $running_ref->{ $keys[$i] } );
				$slist->{data}->[$i] = [ $keys[$i], $status, $text ];
			}
			$progress->set_text( ( $max - $$list_ref->pending ) . "/" . $max );
			$progress->set_fraction( 1 - ( $$list_ref->pending / $max ) );

			Gtk2::Gdk::Threads->leave;
			sleep(1);
		}
	}

	sub _status_ {
		my $not_finished_yet = 1;
		my $finished : shared = 0;

		#		while ($not_finished_yet) {
		while (( $finished < scalar( keys %{$running_ref} ) )
			|| ( $$list_ref->pending > 0 ) )
		{

			#			Gtk2::Gdk::Threads->enter;

			$finished = 0;
			grep { $finished += ( substr( $_, 0, 1 ) =~ /f/ ); }
			  values %{$running_ref};

			#			Gtk2::Gdk::Threads->leave;
			sleep(1);

		}
		&show_summary($CONFIG);
	}

	# all in one go
	$window->show_all;

	my $updater = threads->new( \&_worker_ );
	my $status  = threads->new( \&_status_ );

	Gtk2->main;
	exit 0;
}

sub log_file {
	my $text = shift || die "nothing to log\n";
	my $file = ".log";

	open( FILE, ">>$file" ) || die "error while opening $file : $^E\n";
	print FILE $text . "\n";
	close(FILE);
}


sub array_diff{
	my ($ar1, $ar2) = @_;

	my $diff	= {
			'added' 	=> [],
			'deleted'	=> [],
			'left'		=> 0,
			'right'		=> 0
	};

	my $h1	= {};
	my $h2 	= {};

	grep{ $h1->{$_} = 1; }@{$ar1};
	grep{ $h2->{$_} = 1; }@{$ar2};

	grep{
		if ( !exists($h2->{$_}) ){
			push( @{$diff->{'deleted'}}, $_ );
		}

		$diff->{'left'}++;
	}keys %{$h1};


	grep{
		if ( !exists($h1->{$_}) ){
			push( @{$diff->{'added'}}, $_ );
		}
		$diff->{'right'}++;
	}keys %{$h2};

	return $diff;
}
