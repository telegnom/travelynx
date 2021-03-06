package Travelynx::Controller::Traveling;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use Travel::Status::DE::IRIS::Stations;

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		$self->render(
			'landingpage',
			version           => $self->app->config->{version} // 'UNKNOWN',
			with_autocomplete => 1,
			with_geolocation  => 1
		);
		$self->mark_seen( $self->current_user->{id} );
	}
	else {
		$self->render(
			'landingpage',
			version => $self->app->config->{version} // 'UNKNOWN',
			intro   => 1
		);
	}
}

sub user_status {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $user = $self->get_privacy_by_name($name);

	if ( $user and ( $user->{public_level} & 0x02 ) ) {
		my $status = $self->get_user_status( $user->{id} );
		$self->render(
			'user_status',
			name    => $name,
			journey => $status
		);
	}
	else {
		$self->render('not_found');
	}
}

sub public_status_card {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $user = $self->get_privacy_by_name($name);

	delete $self->stash->{layout};

	if ( $user and ( $user->{public_level} & 0x02 ) ) {
		my $status = $self->get_user_status( $user->{id} );
		$self->render(
			'_public_status_card',
			name    => $name,
			journey => $status
		);
	}
	else {
		$self->render('not_found');
	}
}

sub status_card {
	my ($self) = @_;
	my $status = $self->get_user_status;

	delete $self->stash->{layout};

	if ( $status->{checked_in} ) {
		$self->render( '_checked_in', journey => $status );
	}
	else {
		$self->render( '_checked_out', journey => $status );
	}
}

sub geolocation {
	my ($self) = @_;

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 5 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}
}

sub log_action {
	my ($self) = @_;
	my $params = $self->req->json;

	if ( not exists $params->{action} ) {
		$params = $self->req->params->to_hash;
	}

	if ( not $self->is_user_authenticated ) {

		# We deliberately do not set the HTTP status for these replies, as it
		# confuses jquery.
		$self->render(
			json => {
				success => 0,
				error   => 'Session error, please login again',
			},
		);
		return;
	}

	if ( not $params->{action} ) {
		$self->render(
			json => {
				success => 0,
				error   => 'Missing action value',
			},
		);
		return;
	}

	my $station = $params->{station};

	if ( $params->{action} eq 'checkin' ) {

		my ( $train, $error )
		  = $self->checkin( $params->{station}, $params->{train} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/',
				},
			);
		}
	}
	elsif ( $params->{action} eq 'checkout' ) {
		my ( $still_checked_in, $error )
		  = $self->checkout( $params->{station}, $params->{force} );
		my $station_link = '/s/' . $params->{station};

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => $still_checked_in ? '/' : $station_link,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'undo' ) {
		my $status = $self->get_user_status;
		my $error  = $self->undo( $params->{undo_id} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			my $redir = '/';
			if ( $status->{checked_in} or $status->{cancelled} ) {
				$redir = '/s/' . $status->{dep_ds100};
			}
			$self->render(
				json => {
					success     => 1,
					redirect_to => $redir,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_from' ) {
		my ( undef, $error )
		  = $self->checkin( $params->{station}, $params->{train} );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/',
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_to' ) {
		my ( undef, $error )
		  = $self->checkout( $params->{station}, 1 );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/',
				},
			);
		}
	}
	elsif ( $params->{action} eq 'delete' ) {
		my $error = $self->delete_journey( $params->{id}, $params->{checkin},
			$params->{checkout} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/history',
				},
			);
		}
	}
	else {
		$self->render(
			json => {
				success => 0,
				error   => 'invalid action value',
			},
		);
	}
}

sub station {
	my ($self)  = @_;
	my $station = $self->stash('station');
	my $train   = $self->param('train');

	my $status = $self->get_departures( $station, 120, 30 );

	if ( $status->{errstr} ) {
		$self->render(
			'landingpage',
			version           => $self->app->config->{version} // 'UNKNOWN',
			with_autocomplete => 1,
			with_geolocation  => 1,
			error             => $status->{errstr}
		);
	}
	else {
		# You can't check into a train which terminates here
		my @results = grep { $_->departure } @{ $status->{results} };

		@results = map { $_->[0] }
		  sort { $b->[1] <=> $a->[1] }
		  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
		  @results;

		if ($train) {
			@results
			  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
		}

		$self->render(
			'departures',
			ds100   => $status->{station_ds100},
			results => \@results,
			station => $status->{station_name},
			title   => "travelynx: $status->{station_name}",
		);
	}
	$self->mark_seen( $self->current_user->{id} );
}

sub redirect_to_station {
	my ($self) = @_;
	my $station = $self->param('station');

	$self->redirect_to("/s/${station}");
}

sub cancelled {
	my ($self) = @_;
	my @journeys = $self->get_user_travels( cancelled => 1 );

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'cancelled',
			journeys => [@journeys]
		}
	);
}

sub history {
	my ($self) = @_;

	$self->render( template => 'history' );
}

sub json_history {
	my ($self) = @_;

	$self->render( json => [ $self->get_user_travels ] );
}

sub yearly_history {
	my ($self) = @_;
	my $year = $self->stash('year');
	my @journeys;
	my $stats;

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $year > 1990 and $year < 2100 ) )
	{
		@journeys = $self->get_user_travels;
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => 1,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( years => 1 );
		@journeys = $self->get_user_travels(
			after  => $interval_start,
			before => $interval_end
		);
		$stats = $self->get_journey_stats( year => $year );
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_year',
			journeys   => [@journeys],
			year       => $year,
			statistics => $stats
		}
	);

}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my @journeys;
	my $stats;
	my @months
	  = (
		qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
	  );

	if (
		not(    $year =~ m{ ^ [0-9]{4} $ }x
			and $year > 1990
			and $year < 2100
			and $month =~ m{ ^ [0-9]{1,2} $ }x
			and $month > 0
			and $month < 13 )
	  )
	{
		@journeys = $self->get_user_travels;
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => $month,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( months => 1 );
		@journeys = $self->get_user_travels(
			after  => $interval_start,
			before => $interval_end
		);
		$stats = $self->get_journey_stats(
			year  => $year,
			month => $month
		);
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_month',
			journeys   => [@journeys],
			year       => $year,
			month      => $month,
			month_name => $months[ $month - 1 ],
			statistics => $stats
		}
	);

}

sub journey_details {
	my ($self) = @_;
	my $journey_id = $self->stash('id');

	my $uid = $self->current_user->{id};

	$self->param( journey_id => $journey_id );

	if ( not($journey_id) ) {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid        => $uid,
		journey_id => $journey_id,
		verbose    => 1,
	);

	if ($journey) {
		$self->render(
			'journey',
			error   => undef,
			journey => $journey,
		);
	}
	else {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
	}

}

sub edit_journey {
	my ($self)     = @_;
	my $journey_id = $self->param('journey_id');
	my $uid        = $self->current_user->{id};

	if ( not( $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->render(
			'edit_journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid        => $uid,
		journey_id => $journey_id
	);

	if ( not $journey ) {
		$self->render(
			'edit_journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $error = undef;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);

		my $db = $self->pg->db;
		my $tx = $db->begin;

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser->parse_datetime( $self->param($key) );
			if ( $datetime and $datetime->epoch ne $journey->{$key}->epoch ) {
				$error = $self->update_journey_part( $db, $journey->{id},
					$key, $datetime );
				if ($error) {
					last;
				}
			}
		}

		if ( not $error ) {
			$journey = $self->get_journey(
				uid        => $uid,
				db         => $db,
				journey_id => $journey_id,
				verbose    => 1
			);
			$error = $self->journey_sanity_check($journey);
		}
		if ( not $error ) {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
			return;
		}
	}

	for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival)) {
		if ( $journey->{$key} and $journey->{$key}->epoch ) {
			$self->param(
				$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M') );
		}
	}

	if ( $journey->{route} ) {
		$self->param( route => join( "\n", @{ $journey->{route} } ) );
	}

	$self->render(
		'edit_journey',
		error   => $error,
		journey => $journey
	);
}

sub add_journey_form {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my %opt;

		my @parts = split( qr{\s+}, $self->param('train') );

		if ( @parts == 2 ) {
			@opt{ 'train_type', 'train_no' } = @parts;
		}
		elsif ( @parts == 3 ) {
			@opt{ 'train_type', 'train_line', 'train_no' } = @parts;
		}
		else {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				error =>
'Zug muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
			);
			return;
		}

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			if ( $self->param($key) ) {
				my $datetime = $parser->parse_datetime( $self->param($key) );
				if ( not $datetime ) {
					$self->render(
						'add_journey',
						with_autocomplete => 1,
						error => "${key}: Ungültiges Datums-/Zeitformat"
					);
					return;
				}
				$opt{$key} = $datetime;
			}
		}

		for my $key (qw(dep_station arr_station cancelled comment)) {
			$opt{$key} = $self->param($key);
		}

		my $db = $self->pg->db;
		my $tx = $db->begin;

		$opt{db} = $db;

		my ( $journey_id, $error ) = $self->add_journey(%opt);

		if ( not $error ) {
			my $journey = $self->get_journey(
				uid        => $self->current_user->{id},
				db         => $db,
				journey_id => $journey_id,
				verbose    => 1
			);
			$error = $self->journey_sanity_check($journey);
		}

		if ($error) {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				error             => $error,
			);
		}
		else {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
		}
	}
	else {
		$self->render(
			'add_journey',
			with_autocomplete => 1,
			error             => undef
		);
	}
}

1;
