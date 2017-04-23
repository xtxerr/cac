#!/usr/bin/perl
#
# non-blocking REST-based APIC poller
# copyrights Christian Meutes
#
use warnings;
use strict;
use utf8;
use feature ':5.10';
use IO::Socket;
use POSIX qw(strftime);
use Mojo::DOM;
use Mojo::UserAgent;
use Mojo::Template;
use Mojo::IOLoop::Client;

#################################################################
# max requests per apic controller in parallel
my $max_req = 10;
# where to put data onto the filesystem
my $data_path  = '/yourpath/data/';
# apic credentials
my $apic_user  = 'xxx';
my $apic_pass  = 'yyy';
# apic protocol
my $apic_proto = 'https';
# data hash for APIC login (JSON structure) 
my $apic_credentials = { aaaUser => { attributes => { name => $apic_user, pwd => $apic_pass } } };
# apic http locations
my $login_path = '/api/aaaLogin.json';
my $polcap_path= '/api/class/eqptcapacityEntity.xml?'.
				 'query-target=self&'.
				 'rsp-subtree-include=stats&'.
				 'rsp-subtree-class=eqptcapacityPolUsage5min';
# N and XXX is parsed and substituted in functions
my $ifstats_path = '/api/node/mo/topology/pod-1/node-N/sys/phys-N/HDeqptXXXTotal5min-0.xml';
my $fault_path   = '/api/node/class/faultSummary.xml';
my $node_path    = '/api/node/class/fabricNode.xml';
my $intf_path    = '/api/node/class/topology/pod-1/';
# OpenNMS credentials
my $onms_user  = 'yyy';
my $onms_pass  = 'xxx';
# OpenNMS hostname for REST calls
my $onms_host  = 'opennms.yourdomain.com';
my $onms_nodeurl   = 'http://'.$onms_user.':'.$onms_pass.'@'.$onms_host.'/opennms/rest/nodes/?foreignId=';
# OpenNMS event daemon, Eventd
my $eventd_host    = 'eventd.opennms.yourdomain.com';
my $eventd_tcpport = 5817;
# XML template used to send event to Eventd
my $event_file = '/yourpath/event.xml';
# Define regex which interface statistics *shouldn't* be put into XML files
# Matches on APIC interfaces usage type
# Defining empty list doesn't match on anything: everything is collected
# Use quoted regex eg. (qr/foo/, qr/bar/, qr/notme/)
my @skip_ifusage = (qr/discovery/);
# apic controllers
my @apics = (
	{ name => 'apic-001', ip => '192.0.2.1'  },
	{ name => 'apic-002', ip => '192.0.2.2'  },
	{ name => 'apic-003', ip => '192.0.2.3'  },
);
#################################################################


## MAIN ##

	# {{{ get fqdn of apic nodes #
	##############################
my $ua = new Mojo::UserAgent->new;
my $delay = Mojo::IOLoop::Delay->new;
my $client = Mojo::IOLoop::Client->new;

for my $href (@apics) {
	# turn the name into an IP and back, to see if we can get a canonical FQDN
	my @addr = gethostbyname( $href->{name} );
	my $hostname;
	$href->{hostname} = gethostbyaddr( $addr[4], $addr[2] );
	unless ($href->{hostname}) {
		# if we can't look it back up by the IP address just use the name
		$href->{hostname} = $href->{name};
	}
} # }}}
	# {{{ First event loop, login, get some data, send events #
	###########################################################
# APIC Login, OpenNMS IDs, basic APIC data, faults, send events to ONMS 
# each step is a parallelized but synchronized event queue
Mojo::IOLoop::Delay->new->steps(
	sub {
		my $delay = shift;
		for my $href (@apics) {
			# resolve OpenNMS node IDs
			onms_id( $delay, $ua, $href );
			# login to APIC, set cookie
			apic_login( $delay, $ua, $href );
		}
	},
	sub {
		my $delay = shift;
		for my $href (@apics) {
			# get APIC data and do some cool things
			apic_data( $delay, $ua, $href );
		}
	},
	sub {
		my $delay = shift;
		for my $href (@apics) {
			# for each Mojo::Collection object
			for my $fault ( @{ $href->{faults} } ) {
				# send event to OpenNMS eventd
				send_event( $delay, $client, $fault, $href->{id}, $href->{hostname} );
			}
		}
	}
)->wait; # }}}
	# {{{ Second event loop - get Interface stats of APIC nodes #
#   #############################################################
# we need to create an array for http requests, to pool through them, to not 
# call everything in single non-blocking operation, but to to do N requests in 
# parallel at maximum, else it would end in DoS to apics

my %intfstats;

# create temporary hash of arrays per APIC 
my %requests;
for my $href (@apics) {
	for my $node ( @{ $href->{fabricNodes} } ) {
		for my $intf ( @{ $node->{'l1PhysIf'} } ) {
			if ( $intf->{'adminSt'} eq 'up') {
				push @{ $requests{$href->{name}} }, {
					id => $intf->{'id'},
					usage => $intf->{'usage'},
					node => $node->{id},
					apic => $href->{name},
					apicip => $href->{ip},
					dir => 'Ingr'
				};
				push @{ $requests{$href->{name}} }, {
					id => $intf->{'id'},
					usage => $intf->{'usage'},
					node => $node->{id},
					apic => $href->{name},
					apicip => $href->{ip},
					dir => 'Egr'
				};
			}
		}
	}
}

# Start loop of requests, N at max per APIC, subsequent requests are started
# through callbacks of those requests
$delay = Mojo::IOLoop->delay;

for my $interfaces (values %requests) {
	# for each apic controller an array of hashs, where each hash is an interface
	# $interface is array ref
	ifstats ( $delay, $ua, $interfaces ) for 1 .. $max_req;
}
$delay->wait;

		# {{{ sub Get interface stats, nonblocking recursive callbacks #
		################################################################
sub ifstats {
	my ( $delay, $ua, $queue ) = @_;

	# Stop if there are no more URLs, in the queue
	# this callback is run in each request until queue is empty
	# shift one element out of the queue in each callback
	return unless my $intf_hash = shift @{ $queue };

	my $nodeid = $intf_hash->{node};
	my $intfid = $intf_hash->{id};
	my $ip = $intf_hash->{apicip};
	my $apic = $intf_hash->{apic};
	my $dir = $intf_hash->{dir};

	my $path = $ifstats_path =~ s/node-N/node-$nodeid/r;
	$path =~ s/phys-N/phys-\[$intfid\]/;
	$path =~ s/XXX/$dir/;

	my $ifstats_url = $apic_proto."://".$ip.$path;

	# Create event counter / increment even stack
	my $ifstats_end = $delay->begin;

	$ua->get ( $ifstats_url => { Accept => 'application/xml'} => sub {
		# recursive callback until queue is empty
		my ( $ua, $tx ) = @_;

		if (my $res = $tx->success) {
			my $ifstats_dom = Mojo::DOM->new($tx->res->body);
			my $result = $ifstats_dom->at('eqpt'.$dir.'TotalHist5min');
			if ($result) {
				$intfstats{$apic}->{$nodeid}->{$intfid}->{'eqpt'.$dir.'TotalHist5min'} = $result->attr;
				$intfstats{$apic}->{$nodeid}->{$intfid}->{'eqpt'.$dir.'TotalHist5min-obj'} = $result;
			}
			$ifstats_end->();
			ifstats ( $delay, $ua, $queue );
		} else {
			my $err = $tx->error;
			say "APIC: $intf_hash->{apic}";
			say "Node: $nodeid";
			say "$err->{code} response: $err->{message}" if $err->{code};
			say "Connection error: $err->{message}";
			$ifstats_end->();
			ifstats ( $delay, $ua, $queue );
		}
	});
} # }}}
		# {{{ Merge interface counters from %intfstats hash into main data structure #
		##############################################################################
for my $href (@apics) {
	for my $node ( @{ $href->{fabricNodes} } ) {
		for my $intf ( @{ $node->{'l1PhysIf'} } ) {
			if ( $intf->{'adminSt'} eq 'up') {
				$intf->{'eqptEgrTotalHist5min'} =
					$intfstats{$href->{name}}->{$node->{'id'}}->{$intf->{'id'}}->{eqptEgrTotalHist5min};
				$intf->{'eqptIngrTotalHist5min'} =
					$intfstats{$href->{name}}->{$node->{'id'}}->{$intf->{'id'}}->{eqptIngrTotalHist5min};
			}
		}
	}
} # }}}

# }}}
	# {{{ Create interface stats XML files #
    ########################################
# create simple hash for OpenNMS XML file creation
# create id with node and interface id in one string, used in OpenNMS
my %ifstats;
for my $href (@apics) {
	for my $node ( @{ $href->{fabricNodes} } ) {
		for my $intf ( @{ $node->{'l1PhysIf'} } ) {
			if ( $intf->{'adminSt'} eq 'up' ) {
				# replace interface-id separator / with - 
				my $ifid = $intf->{'id'} =~ s/\//-/rg;
				# create id = nodeid_ifid-subifid
				my $id = "node-".$node->{id}."_".$ifid;
				# port description 'ifAlias'
				$ifstats{$href->{'name'}}->{$intf->{'usage'}}->{$id}->{'descr'} = $intf->{'descr'};
				# statistics
				for my $attr (keys %{ $intf->{'eqptIngrTotalHist5min'} }) {
					$ifstats{$href->{'name'}}->{$intf->{'usage'}}->{$id}->{'eqptIngrTotalHist5min'} 
						.= qq( $attr="$intf->{'eqptIngrTotalHist5min'}->{$attr}");
				}
				for my $attr (keys %{ $intf->{'eqptEgrTotalHist5min'} }) {
					$ifstats{$href->{'name'}}->{$intf->{'usage'}}->{$id}->{'eqptEgrTotalHist5min'} 
						.= qq( $attr="$intf->{'eqptEgrTotalHist5min'}->{$attr}");
				}
			}
		}
	}
}

# create XML files ,call dedicated function
ifstats_xml ( \%ifstats );
# }}}

### MAIN END ##

	# {{{ sub ifstats_xml #
	#######################
# create interface stats xml files for OpenNMS
sub ifstats_xml {
	my $ifstats_hashref = shift;

	for my $aref (keys %{ $ifstats_hashref } ) {
		# Create ifstats files for OpenNMS
		my $filename = $data_path."/capacity/interfaces/".$aref.".xml";
		open(my $fh, '>', $filename) or say "Could not open file '$filename' $!";
		if ($fh) {
			my $statsxml= qq(<ifstats>);
			for my $usage (keys %{ $ifstats_hashref->{$aref} } ) {
				my $regex = join '|', @skip_ifusage, '(?!)';
				next if $usage =~ /$regex/;
				for my $id (sort (keys %{ $ifstats_hashref->{$aref}->{$usage} })) {
					my $ingress = $ifstats_hashref->{$aref}->{$usage}->{$id}->{'eqptIngrTotalHist5min'};
					my $egress = $ifstats_hashref->{$aref}->{$usage}->{$id}->{'eqptEgrTotalHist5min'};
					my $descr  = $ifstats_hashref->{$aref}->{$usage}->{$id}->{'descr'};
					$descr = " - " unless $descr;
					if ( $ingress or $egress ) {
						$statsxml .= qq(  <id nodeIf="$id" usage="$usage" descr="$descr" >);
						$statsxml .= qq(    <eqptIngrTotalHist5min$ingress />);
						$statsxml .= qq(    <eqptEgrTotalHist5min$egress />);
						$statsxml .= qq(  </id>);
					}
				}
			}
			$statsxml .= qq(</ifstats>);
			print $fh $statsxml;
			close $fh;
		} else {
			say "Oops, something went wrong, can't create interface data";
		}
	}
} # }}}
	# sub apic_login {{{ #
	######################
sub apic_login {
	my ( $delay, $ua, $aref ) = @_;

	my $url = $apic_proto."://".$aref->{ip}.$login_path;
	# Create event counter / increment even stack
	my $end = $delay->begin;

	$ua->post ($url => json => $apic_credentials => sub {
		# Callback
		my ( $ua, $tx ) = @_;
		if (my $res = $tx->success) {
			#decrement event counter
			$end->();
		} else {
			# error
			my $err = $tx->error;
			say "$err->{code} response: $err->{message}" if $err->{code};
			say "Connection error: $err->{message}";
			# decrement event counter
			$end->();
		}
	});
} # }}}
	# sub apic_data {{{ #
	#####################
sub apic_data {
	my ( $delay, $ua, $aref ) = @_;

	# start policer-capacity data execution
	pol_capacity ( $delay, $ua, $aref );

	# start faults data execution
	faults ( $delay, $ua, $aref );

	# start nodes & interface data
	# this is redundant to node_intf, nodes() is using more complexity but less code
	#nodes ( $delay, $ua, $aref );

	# start nodes & interface data
	node_intf ( $delay, $ua, $aref );
} # }}}
	# sub ua_get {{{ #
	##################
sub ua_get {
	my ( $delay, $ua, $url, $aref, $helper ) = @_;

	# Create event counter / increment even stack
	my $end = $delay->begin;

	$ua->get ($url => { Accept => 'application/xml'} => sub {
		# Callback
		my ( $ua, $tx ) = @_;
		if (my $res = $tx->success) {
			# use helper function to do individual things
			$helper->( $delay, $ua, $tx, $aref );
			#decrement event counter
			$end->();
		} else {
			my $err = $tx->error;
			say "$err->{code} response: $err->{message}" if $err->{code};
			say "Connection error: $err->{message}";
			#decrement event counter
			$end->();
		}
	});
} # }}}
	# sub pol-capacity {{{ #
	########################
sub pol_capacity {
	my ( $delay, $ua, $aref ) = @_;

	# pol_capacity code, used in outsourced ua_get() function
	my $helper = sub {
		my ( $delay, $ua, $tx, $aref ) = @_;

		# Replace full DN in capacity data with simple DN (just node name)
		my $dom = Mojo::DOM->new($tx->res->body);
		for my $el ($dom->find('eqptcapacityEntity')->each) {
			$el->attr->{dn} =~ s/.*?\/(node-\d+).*/$1/;
		}
		# Create pol_capacity files for OpenNMS
		my $filename = $data_path."/capacity/policer-cam/".$aref->{name}."-pol-capacity.xml";
		open(my $fh, '>', $filename) or say "Could not open file '$filename' $!";
		if ($fh & $dom) {
			print $fh $dom->to_string;
			close $fh;
		} else {
			say "Oops, something went wrong, can't create policer capacity data";
		}
	};
	my $polcap_url = $apic_proto."://".$aref->{ip}.$polcap_path;
	# non-blocking call to ua_get()
	ua_get( $delay, $ua, $polcap_url, $aref, $helper );
} # }}}
	# sub faults {{{ #
	##################
sub faults {
	my ( $delay, $ua, $aref ) = @_;

	# fault code, used in outsourced ua_get() function
	my $helper = sub {
		my ( $delay, $ua, $tx, $aref ) = @_;

		my $dom = Mojo::DOM->new($tx->res->body);
		for my $el ($dom->find('faultSummary')->each) {
			# put fault object into data hash
			# ('Mojo::DOM::HTML' object)
			push @{ $aref->{faults} }, $el;
		}
	};
	my $fault_url = $apic_proto."://".$aref->{ip}.$fault_path;
	# non-blocking call to ua_get()
	ua_get( $delay, $ua, $fault_url, $aref, $helper );
} # }}}
	# sub nodes {{{ #
	#################
sub nodes {
	my ( $delay, $ua, $aref ) = @_;

	my $intf_helper = sub {
		my ( $delay, $ua, $tx, $apic_node ) = @_;
		my ( $node, $aref ) = ( $apic_node->{node}, $apic_node->{apic} );

		my $attr = { %{ $node->attr } };
		my $intf_dom = Mojo::DOM->new($tx->res->body);
		#Iterate over all interfaces
		for my $intf ($intf_dom->find('l1PhysIf')->each) {
			# Push attributes of interface to array inside node hash
			push @{$attr->{l1PhysIf}}, $intf->attr;
		}
		# Push node hash as array element to apic node
		push @{$aref->{fabricNodes}}, $attr;
	};
	my $helper = sub {
		my ( $delay, $ua, $tx, $aref ) = @_;

		my $dom = Mojo::DOM->new($tx->res->body);
		# Iterate over all nodes
		for my $node ($dom->find('fabricNode')->each) {
			# Get all interfaces of the node
			my $intf_url = $apic_proto."://".$aref->{ip}.$intf_path."node-".$node->{id}."/l1PhysIf.xml";
			# create av/pair for next callback (intf_helper)
			my $apic_node = { apic => $aref, node => $node };
			ua_get( $delay, $ua, $intf_url, $apic_node, $intf_helper );
		}
	};
	my $node_url = $apic_proto."://".$aref->{ip}.$node_path;
	# non-blocking call to ua_get()
	ua_get( $delay, $ua, $node_url, $aref, $helper );
} # }}}
	# sub node_intf {{{ #
	#####################
# dedicated function for continues call passing of node and then interfaces
sub node_intf {
	my ( $delay, $ua, $aref ) = @_;

	my $node_url = $apic_proto."://".$aref->{ip}.$node_path;
	# Create event counter / increment even stack

	my $end = $delay->begin;

	$ua->get ( $node_url => { Accept => 'application/xml'} => sub {

		# callback #1
		my ( $ua, $tx ) = @_;
		if (my $res = $tx->success) {
			my $dom = Mojo::DOM->new($tx->res->body);

			# Iterate over all nodes
			for my $node ($dom->find('fabricNode')->each) {
				# consider only active nodes
				next if $node->{fabricSt} ne "active";

				my $intf_url = $apic_proto."://".$aref->{ip}.$intf_path."node-".$node->{id}."/l1PhysIf.xml";
				# Create event counter / increment even stack

				my $intf_end = $delay->begin;
				# Get all interfaces of the node
				$ua->get ( $intf_url => { Accept => 'application/xml'} => sub {

					# callback #2
					my ( $ua, $tx ) = @_;

					if (my $res = $tx->success) {

						my $attr = { %{ $node->attr } };
						my $intf_dom = Mojo::DOM->new($tx->res->body);

						#Iterate over all interfaces
						for my $intf ($intf_dom->find('l1PhysIf')->each) {
							# Push attributes of interface to array inside node hash
							push @{$attr->{l1PhysIf}}, $intf->attr;

						}
						# Push node hash as array element to apic node
						push @{$aref->{fabricNodes}}, $attr;
						#decrement event counter
						$intf_end->();
					} else {
						my $err = $tx->error;
						say "APIC: $aref->{name}";
						say "Node: $node->{id}";
						say "$err->{code} response: $err->{message}" if $err->{code};
						say "Connection error: $err->{message}";
						#decrement event counter
						$intf_end->();
					}
				});
			}
			#decrement event counter
			$end->();
		} else {
			my $err = $tx->error;
			say "APIC: $aref->{name}";
			say "$err->{code} response: $err->{message}" if $err->{code};
			say "Connection error: $err->{message}";
			#decrement event counter
			$end->();
		}
	});
} # }}}
	# sub onms_id {{{ #
	###################
sub onms_id {
	my ( $delay, $ua, $aref ) = @_;
	my $helper = sub {
		my ( $delay, $ua, $tx, $aref ) = @_;
		# set id
		my $dom = Mojo::DOM->new($tx->res->body);
		$aref->{id} = $dom->at('nodes > node')->attr('id');
	};
	my $onms_url = $onms_nodeurl.$aref->{name};
	# non-blocking call to ua_get()
	ua_get( $delay, $ua, $onms_url, $aref, $helper );
} # }}}
	# sub send_event {{{ #
	######################
sub send_event {
	my ( $delay, $client, $fault, $node_id, $hostname ) = @_;

	# create time string
	my $time = strftime '%A, %d %B %Y %-H:%M:%S o\'clock GMT', gmtime();

	# convert apic severity 'info' to opennms severity 'normal'
	my $severity = $fault->attr->{'severity'};
	if ($severity eq "info") {
		$severity = 'normal';
	}
	$severity = ucfirst(lc($severity));

	# read and process event template
	my $mt = Mojo::Template->new;
	my $event = $mt->render_file($event_file, $fault, $node_id, $hostname, $severity, $time );

	# connect to OpenNMS eventd and transmit event
	my $socket = IO::Socket::INET->new(
		PeerAddr => $eventd_host,
		PeerPort => $eventd_tcpport,
		Proto => "tcp",
		Type => SOCK_STREAM
	) or say "Couldn't connect to $eventd_host:$eventd_tcpport - $@\n";
	if ($socket) {
		print $socket $event;
		$socket->close();
	}
} # }}}

