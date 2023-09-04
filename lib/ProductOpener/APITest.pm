# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2023 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

ProductOpener::APITest - utility functions to interact with API

=head1 DESCRIPTION

=cut

package ProductOpener::APITest;

use ProductOpener::PerlStandards;
use Exporter qw< import >;

BEGIN {
	use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(
		&construct_test_url
		&create_user
		&edit_user
		&edit_product
		&get_page
		&html_displays_error
		&login
		&mails_from_log
		&mail_to_text
		&new_client
		&normalize_mail_for_comparison
		&post_form
		&tail_log_start
		&tail_log_read
		&wait_application_ready
		&wait_dynamic_front
		&execute_api_tests
		&wait_server
		&fake_http_server
		&get_minion_jobs
	);    # symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK;

use ProductOpener::TestDefaults qw/:all/;
use ProductOpener::Test qw/:all/;
use ProductOpener::Mail qw/$LOG_EMAIL_START $LOG_EMAIL_END/;
use ProductOpener::Store qw/store retrieve/;
use ProductOpener::Producers qw/get_minion/;

use Test::More;
use LWP::UserAgent;
use HTTP::CookieJar::LWP;
use HTTP::Request::Common;
use Encode;
use JSON::PP;
use Carp qw/confess/;
use Clone qw/clone/;
use File::Tail;
use Test::Fake::HTTPD;
use Minion;

# Constants of the test website main domain and url
# Should be used internally only (see: construct_test_url to build urls in tests)
my $TEST_MAIN_DOMAIN = "openfoodfacts.localhost";
my $TEST_WEBSITE_URL = "http://world." . $TEST_MAIN_DOMAIN;

=head2 wait_dynamic_front()

Wait for dynamic_front to be ready.
It's important because the application might fail because of that

=cut

sub wait_dynamic_front() {

	# simply try to access a resource generated by dynamicfront
	my $count = 0;
	while (1) {
		last if (-e "/opt/product-opener/html/images/icons/dist/barcode.svg");
		sleep 1;
		$count++;
		if (($count % 3) == 0) {
			print("Waiting for dynamicfront to be ready since $count seconds...\n");
		}
		confess("Waited too much for backend") if $count > 100;
	}
	return;
}

=head2 wait_server()

Wait for server to be ready.
It's important because the application might fail because of that

=cut

sub wait_server() {

	# simply try to access front page
	my $count = 0;
	my $ua = new_client();
	my $target_url = construct_test_url("");
	while (1) {
		my $response = $ua->get($target_url);
		last if $response->is_success;
		sleep 1;
		$count++;
		if (($count % 3) == 0) {
			print("Waiting for backend to be ready since more than $count seconds...\n");
			diag explain({url => $target_url, status => $response->code, response => $response});
		}
		confess("Waited too much for backend") if $count > 60;
	}
	return;
}

=head2 wait_application_ready()

Wait for server and dynamic front to be ready.
Run this at the beginning of every integration test

=cut

sub wait_application_ready() {
	wait_server();
	wait_dynamic_front();
	return;
}

=head2 new_client()

Reset user agent

=head3 return value

Return a user agent

=cut

sub new_client () {
	my $jar = HTTP::CookieJar::LWP->new;
	my $ua = LWP::UserAgent->new(cookie_jar => $jar);
	# set a neutral user-agent, for it may appear in some results
	$ua->agent("Product-opener-tests/1.0");
	return $ua;
}

=head2 create_user($ua, $args_ref)

Call API to create a user

=head3 Arguments

=head4 $ua - user agent

=head4 $args_ref - fields

=cut

sub create_user ($ua, $args_ref) {
	my %fields = %{clone($args_ref)};
	my $tail = tail_log_start();
	my $response = $ua->post("$TEST_WEBSITE_URL/cgi/user.pl", Content => \%fields);
	if (not $response->is_success) {
		diag("Couldn't create user with " . explain(\%fields) . "\n");
		diag explain $response;
		diag("\n\nLog4Perl Logs: \n" . tail_log_read($tail) . "\n\n");
		confess("\nResuming");
	}
	return $response;
}

=head2 edit_user($ua, $args_ref)

Call API to edit a user, see create_user

=cut

sub edit_user ($ua, $args_ref) {
	($args_ref->{type} eq "edit") or confess("Action type must be 'edit' in edit_user");
	# technically the same as create_user !
	return create_user($ua, $args_ref);
}

=head2 login($ua, $user_id, $password)

Login as a user

=cut

sub login ($ua, $user_id, $password) {
	my %fields = (
		user_id => $user_id,
		password => $password,
		".submit" => "submit",
	);
	my $response = $ua->post("$TEST_WEBSITE_URL/cgi/login.pl", Content => \%fields);
	if (not($response->is_success || $response->is_redirect)) {
		diag("Couldn't login with " . explain(\%fields) . "\n");
		diag explain $response;
		confess("Resuming");
	}
	return $response;
}

=head2 get_page ($ua, $url)

Get a page of the app

=head3 Arguments

=head4 $ua - user agent

=head4 $url - absolute url

=cut

sub get_page ($ua, $url) {
	my $response = $ua->get("$TEST_WEBSITE_URL$url");
	if (not $response->is_success) {
		diag("Couldn't get page $url\n");
		diag explain $response;
		confess("Resuming");
	}
	return $response;
}

=head2 post_form ($ua, $url, $fields_ref)

Post a form

=head3 Arguments

=head4 $ua - user agent

=head4 $url - absolute url

=head4 $fields_ref

Reference of a hash of fields to pass as the form result

=cut

sub post_form ($ua, $url, $fields_ref) {
	my $response = $ua->post("$TEST_WEBSITE_URL$url", Content => $fields_ref);
	if (not $response->is_success) {
		diag("Couldn't submit form $url with " . explain($fields_ref) . "\n");
		diag explain $response;
		confess("Resuming");
	}
	return $response;
}

=head2 edit_product($ua, $product_fields_ref)

Call the API to edit a product. If the product does not exist, it will be created.

=head3 Arguments

=head4 $ua - user agent

=head4 $product_fields_ref

Reference of a hash of product fields to pass to the API

=cut

sub edit_product ($ua, $product_fields) {
	my %fields;
	while (my ($key, $value) = each %{$product_fields}) {
		$fields{$key} = $value;
	}

	my $response = $ua->post("$TEST_WEBSITE_URL/cgi/product_jqm2.pl", Content => \%fields,);
	if (not $response->is_success) {
		diag("Couldn't create product with " . explain(\%fields) . "\n");
		diag explain $response;
		confess("Resuming");
	}
	return $response;
}

=head2 html_displays_error($page)

Return if a form displays errors

Most forms will return a 200 while displaying an error message.
This function assumes error_list.tt.html was used.
=cut

sub html_displays_error ($page) {
	return index($page, '<li class="error">') > -1;
}

=head2 construct_test_url()

Constructs the URL to send the HTTP request to for the API.

=head3 Arguments

Takes in two string arguments, One being the the target and other a prefix. 
The prefix could be simply the country code (eg: US for America or "World") OR something like ( {country-code}-{language-code} )

An example below
$target = "/product/35242200055"
$prefix= "world-fr"  

=head3 Return Value

Returns the constructed URL for the query 

For the example cited above this returns: "http://world-fr.openfoodfacts.localhost/product/35242200055"

=cut

sub construct_test_url ($target, $prefix = "world") {
	my $link = $TEST_MAIN_DOMAIN;
	# no cgi inside url ? add display.pl
	if ($target !~ /^\/cgi\//) {
		$link .= "/cgi/display.pl?";
	}
	my $url = "http://${prefix}.${link}${target}";
	return $url;
}

=head2 origin_from_url($url)

Compute "Origin" header for $url

=cut

sub origin_from_url ($url) {
	return $url =~ /^(\w+:\/\/[^\/]+)\//;
}

=head2 execute_api_tests($file, $tests_ref, $ua=undef)

Initialize tests and execute them.

=head3 Arguments

=head4 $file test file name

The *.t test files call execute_api_tests() with _FILE_ as the first parameter,
and the directories for the tests are derived from it.

=head4 $tests_ref reference to list of tests

The tests are in a structure like this:

my $tests_ref = (
    [
		{
			# request description
			test_case => 'no-body',  # a description of the test, should be unique to easily retrieve which test failed
			method => 'POST',		# defaults to GET
			subdomain => 'world',	# defaults to "world"
			path => '/api/v3/product/12345678',
			query_string => '?some_param=some_value&some_other_param=some_other_value'	# optional
			form => { field_name => field_value, .. },	# optional, will not be sent if there is a body
			headers_in => {header1 => value1},  # optional, headers to add to request
			body => '{"some_json_field": "some_value"}',  # optional, will be fetched in file in needed
			ua => a LWP::UserAgent object, if a specific user is needed (e.g. with moderator status)

			# expected return
			headers => {header1 => value1, }  # optional. You may add an undef value to test for the inexistance of a header
			response_content_must_match => "regexp"	# optional. You may add a case insensitive regexp (e.g. "Product saved") that must be matched
			response_content_must_not_match => "regexp"	# optional. You may add a case insensitive regexp (e.g. "error") that must not be matched
		}
    ],
);

=head4 $ua a web client (LWP::UserAgent) to use

If undef we open a new client.

You might need this to test with an authenticated user.

Note: this setting can be overriden for each test case by specifying a "ua" field.

=cut

sub execute_api_tests ($file, $tests_ref, $ua = undef) {

	my ($test_id, $test_dir, $expected_result_dir, $update_expected_results) = (init_expected_results($file));

	$ua = $ua // LWP::UserAgent->new();

	foreach my $test_ref (@$tests_ref) {

		# We may have a test case specific user agent
		my $test_ua = $test_ref->{ua} // $ua;

		my $test_case = $test_ref->{test_case};
		my $url = construct_test_url($test_ref->{path} . ($test_ref->{query_string} || ''),
			$test_ref->{subdomain} || 'world');

		my $method = $test_ref->{method} || 'GET';

		my $response;

		my $headers_in = {"Origin" => origin_from_url($url)};
		if (defined $test_ref->{headers_in}) {
			# combine with computed headers
			$headers_in = {%$headers_in, %{$test_ref->{headers_in}}};
		}

		# Send the request
		if ($method eq 'OPTIONS') {
			# not yet supported by our (system) version of HTTP::Request::Common
			# $response = $ua->request(OPTIONS($url));
			# hacky: use internal method
			my $request = HTTP::Request::Common::request_type_with_data("OPTIONS", $url, %$headers_in);
			$response = $test_ua->request($request);
		}
		elsif ($method eq 'GET') {
			$response = $test_ua->get($url, %$headers_in);
		}
		elsif ($method eq 'POST') {
			if (defined $test_ref->{body}) {
				$response = $test_ua->post(
					$url,
					Content => encode_utf8($test_ref->{body}),
					"Content-Type" => "application/json; charset=utf-8",
					%$headers_in
				);
			}
			elsif (defined $test_ref->{form}) {
				my $form = $test_ref->{form};
				my $is_multipart = 0;
				foreach my $value (values %$form) {
					if (ref($value) eq 'ARRAY') {
						$is_multipart = 1;
						last;
					}
				}
				if ($is_multipart) {
					$response = $test_ua->post(
						$url,
						"Content-Type" => "multipart/form-data",
						Content => $form,
						%$headers_in
					);
				}
				else {
					$response = $test_ua->post($url, Content => $form, %$headers_in);
				}
			}
			else {
				$response = $test_ua->post($url, %$headers_in);
			}
		}
		elsif ($method eq 'PUT') {
			$response = $test_ua->put(
				$url,
				Content => encode_utf8($test_ref->{body}),
				"Content-Type" => "application/json; charset=utf-8",
				%$headers_in,
			);
		}
		elsif ($method eq 'DELETE') {
			$response = $test_ua->delete(
				$url,
				Content => encode_utf8($test_ref->{body}),
				"Content-Type" => "application/json; charset=utf-8",
				%$headers_in,
			);
		}
		elsif ($method eq 'PATCH') {
			my $request = HTTP::Request::Common::PATCH(
				$url,
				Content => encode_utf8($test_ref->{body}),
				"Content-Type" => "application/json; charset=utf-8",
				%$headers_in,
			);
			$response = $test_ua->request($request);
		}

		# Check if we got the expected response status code, expect 200 if not provided
		if (not defined $test_ref->{expected_status_code}) {
			$test_ref->{expected_status_code} = 200;
		}

		is($response->code, $test_ref->{expected_status_code}, "$test_case - Test status")
			or diag(explain($test_ref), "Response status line: " . $response->status_line);

		if (defined $test_ref->{headers}) {
			while (my ($hname, $hvalue) = each %{$test_ref->{headers}}) {
				my $rvalue = $response->header($hname);
				# one may put undef values to test the inexistance of a header
				if (!defined $hvalue) {
					ok(!defined $rvalue, "$test_case - header $hname should not be defined");
				}
				else {
					is($rvalue, $hvalue, "$test_case - header $hname");
				}
			}
		}

		my $response_content = $response->decoded_content;

		if ((defined $test_ref->{expected_type}) and ($test_ref->{expected_type} eq 'text')) {
			# Check that the text file is the same as expected (useful for checking dynamic robots.txt)
			is(
				compare_file_to_expected_results(
					$response_content, "$expected_result_dir/$test_case.txt",
					$update_expected_results, $test_ref
				),
				1,
				"$test_case - result"
			);
		}
		elsif (not((defined $test_ref->{expected_type}) and ($test_ref->{expected_type} eq "html"))) {

			# Check that we got a JSON response

			my $decoded_json;
			eval {
				$decoded_json = decode_json($response_content);
				1;
			} or do {
				my $json_decode_error = $@;
				diag(
					"$test_case - The $method request to $url returned a response that is not valid JSON: $json_decode_error"
				);
				diag("Response content: " . $response_content);
				fail($test_case);
				next;
			};

			# normalize for comparison
			if (ref($decoded_json) eq 'HASH') {
				if (defined $decoded_json->{'products'}) {
					normalize_products_for_test_comparison($decoded_json->{'products'});
				}
				if (defined $decoded_json->{'product'}) {
					normalize_product_for_test_comparison($decoded_json->{'product'});
				}
			}

			is(
				compare_to_expected_results(
					$decoded_json, "$expected_result_dir/$test_case.json",
					$update_expected_results, $test_ref
				),
				1,
				"$test_case - result"
			);
		}

		# Check if the response content matches what we expect
		my $must_match = $test_ref->{response_content_must_match};
		if (    (defined $must_match)
			and ($response_content !~ /$must_match/i))
		{
			fail($test_case);
			diag("Must match: " . $must_match . "\n" . "Response content: " . $response_content);
		}

		my $must_not_match = $test_ref->{response_content_must_not_match};
		if (    (defined $must_not_match)
			and ($response_content =~ /$must_not_match/i))
		{
			fail($test_case);
			diag("Must not match: " . $must_not_match . "\n" . "Response content: " . $response_content);
		}

	}
	return;
}

=head2 tail_log_start($log_path)

Start monitoring a log file

=head3 Arguments

=head4 String $log_path

Defaults to /var/log/apache2/log4perl.log

=head3 Returns

An object to pass to tail_log_read to read

=cut

sub tail_log_start ($log_path = "/var/log/apache2/log4perl.log") {
	# we use nowait mode to avoid loosing time in test
	# but beware, this means we will have to manually call checkpending()
	# before reading
	my $tail = File::Tail->new(name => $log_path, nowait => 1);
	return $tail;
}

=head2 tail_log_read($tail)

Return all content written to a log file since last check

=head3 Arguments

=head4 $tail

Object returned by tail_log_start

=head3 Returns

Content as a string

=cut

sub tail_log_read ($tail) {
	# we want to do a nowait read,
	# but we bypass all the predict stuff from File::Tail
	# by directly using checkpending
	$tail->checkpending();
	my @contents = ();
	while (my $line = $tail->read()) {
		push @contents, $line;
	}
	return join "", @contents;
}

=head2 mails_from_log($text)
Retrieve mails in a log extract
=cut

sub mails_from_log ($text) {
	# use delimiter to get it (using non greedy match)
	# /g to match all and /s to treat \n as normal chars
	my @mails = ($text =~ /$LOG_EMAIL_START(.*?)$LOG_EMAIL_END/gs);
	return @mails;
}

=head2 mail_to_text($text)
Make mail more easy to search by removing some specific formatting

Especially we replace "3D=" for "=" and join line and their continuation
=head3 Arguments

=head4 $mail text of mail

=head3 Returns
Reformatted text
=cut

sub mail_to_text ($mail) {
	my $text = $mail;
	# = at line ending indicates a continuation line
	$text =~ s/=\n//mg;
	# =3D means =
	$text =~ s/=3D/=/g;
	return $text;
}

=head2 normalize_mail_for_comparison($mail)

Replace parts of mail that varies from tests to tests,
and also in a format that's nice in json.
=head3 Arguments

=head4 $mail text of mail

=head3 Returns
ref to an array of lines of the email
=cut

sub normalize_mail_for_comparison ($mail) {
	# remove boundaries
	$DB::single = 1;
	my $text = mail_to_text($mail);
	my @boundaries = $text =~ m/boundary=([^ ,\n\t]+)/g;
	foreach my $boundary (@boundaries) {
		$text =~ s/$boundary/boundary/g;
	}
	# replace generic dates
	$text =~ s/\d\d\d\d-\d\d-\d\d/--date--/g;
	# split on \n to get readable json results
	my @lines = split /\n/, $text;
	# replace date headers
	@lines = map {my $text = $_; $text =~ s/^Date: .+/Date: ***/g; $text;} @lines;
	return \@lines;
}

=head2 fake_http_server($port, $dump_path, $responses_ref) {

Launch a fake HTTP server.

We use that to simulate Robotoff or any HTTP API in integration tests.
As it will be launched on the local backend container, we have to pretend
those service URL is on C<backend:$port>.

You can provide a list of responses to simulate real service responses,
while requests sent are store for later checks by the tests.

=head3 parameters

=head4 $dump_path - path

A temporary directory to dump requests

You can retrieve requests, in this directory as C<req-n.sto>

=head4 $responses_ref - ref to a list

List of responses to send, in right order, for each received request.

If the number of request exceed this list,
we will send simple 200 HTTP responses with a json payload.

=head3 returns ref to fake server

Hold the reference until you don't need the server

=cut

sub fake_http_server ($port, $dump_path, $responses_ref) {

	# dump responses
	my $resp_num = 0;
	foreach my $resp (@$responses_ref) {
		store("$dump_path/resp-$resp_num.sto", $resp);
		$resp_num += 1;
	}

	my $httpd = Test::Fake::HTTPD->new(
		timeout => 1000,
		listen => 10,
		host => "0.0.0.0",
		port => $port,
	);

	$httpd->run(
		sub {
			my $req = shift;
			my @dumped_reqs = glob("$dump_path/req-*.sto");
			my $num_req = scalar @dumped_reqs;
			# dump request to the folder
			store("$dump_path/req-$num_req.sto", $req);
			# look for an eventual response
			my $response_ref;
			if (-e "$dump_path/resp-$num_req.sto") {
				$response_ref = retrieve("$dump_path/resp-$num_req.sto");
			}
			else {
				# an ok response
				$response_ref = HTTP::Response->new("200", "OK", HTTP::Headers->new(), '{"foo": "blah"}');
			}
			return $response_ref;
		}
	);
	return $httpd;
}

=head2 get_minion_jobs($task_name, $created_after_ts, $max_waiting_time)
Subprogram which wait till the minion finished its job or
if it takes too much time

=head3 Arguments

=head4 $task_name
The name of the task 

=head4 $created_after_ts
The timestamp of the creation of the task

=head4 $max_waiting_time
The max waiting time for this given task

=head3 Returns
Returns a list of jobs information associated with the task_name

Note: for each job we return the job information (as returned by the jobs() iterator),
not the Minion job object.

=cut

sub get_minion_jobs ($task_name, $created_after_ts, $max_waiting_time) {
	my $waited = 0;    # counting the waiting time
	my %run_jobs = ();
	my $jobs_complete = 0;
	while (($waited < $max_waiting_time) and (not $jobs_complete)) {
		my $jobs = get_minion()->jobs({tasks => [$task_name]});
		# iterate on jobs
		$jobs_complete = 1;
		while (my $job = $jobs->next) {
			next if (defined $run_jobs{$job->{id}});
			# only those who were created after the timestamp
			if ($job->{created} >= $created_after_ts) {
				# retrieving the job id
				my $job_id = $job->{id};
				# retrieving the job state
				my $job_state = $job->{state};
				# check if the job is done
				if (($job_state eq "active") or ($job_state eq "inactive")) {
					$jobs_complete = 0;
					sleep(2);
					$waited += 2;
				}
				else {
					$run_jobs{$job_id} = $job;
				}
			}
		}
	}
	# sort by creation date to have jobs in predictable order
	my @all_jobs = sort {$_->info->{created}} (values %run_jobs);
	return \@all_jobs;
}

1;
