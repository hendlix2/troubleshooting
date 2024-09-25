#!/usr/bin/perl

use strict;
use warnings;
use POSIX qw(strftime);
use MIME::Lite;
use Net::SSH2::Cisco;
use Text::CSV;
use JSON;
use File::Slurp;  # To read the JSON file

# SNMP details
my $community = "community";
my $oid = "iso.3.6.1.2.1.1.3.0";

# Email details
my $sender = 'peter.hendlinger@domain.com';
my @recipients = ('peter@domain1.com','peter@domain2.de');
my $subject = "Alert: Device Uptime Less Than 10 Minutes";
my $test_subject = "Daily Test Email: Device Uptime Check";
my $unreachable_subject = "Alert: Multiple Devices Not Reachable";

# SSH details for the switches
my $ssh_user = "Username";
my $ssh_pass = "password";
my $enable_pass = "enable_password";

# Load JSON data from file
my $json_file = '/specify/path/to/your/switches.json';  # Specify your JSON file path
my $json_text = read_file($json_file);  # Read JSON file as text

# Parse JSON into a Perl data structure
my $data = decode_json($json_text);

# Extract device IPs and interfaces from the JSON structure
my @devices = ();
my %device_interfaces = ();

foreach my $switch (@{$data->{switches}}) {
    my $ip = $switch->{ip};
    push @devices, $ip;
    $device_interfaces{$ip} = $switch->{interfaces};
}

# Timestamp file to track the last daily email sent date
my $timestamp_file = "/tmp/last_email_sent_date13.txt";

# Counter for unreachable devices
my $unreachable_count = 0;

# Array to store unreachable devices
my @unreachable_devices;

# Hash to store uptime information for the daily email
my %uptime_info;



# Function to send an email
sub send_email {
    my ($subject, $body, $attachment) = @_;

    my $msg = MIME::Lite->new(
        From    => $sender,
        To      => join(',', @recipients),
        Subject => $subject,
        Data    => $body,
    );

    if ($attachment) {
        $msg->attach(
            Type     => 'text/csv',
            Path     => $attachment,
            Filename => 'AP_Details.csv',
            Disposition => 'attachment'
        );
    }

    $msg->send or die "Failed to send email: $!";
    print "Email sent successfully with subject: $subject\n";
}

# Function to convert minutes to days, hours, and minutes
sub format_uptime {
    my ($minutes) = @_;
    my $days = int($minutes / 1440);
    $minutes %= 1440;
    my $hours = int($minutes / 60);
    $minutes %= 60;
    return sprintf("%d days, %d hours, %d minutes", $days, $hours, $minutes);
}

sub execute_ssh_commands {
    my ($switches_ref, $interfaces_ref) = @_;

    my %actions;  # Hash to track actions for each host

    # Step 1: Shut down all interfaces on all switches
    foreach my $host (@$switches_ref) {
        my @shut_interfaces;

        # Establish SSH connection
        my $session = Net::SSH2::Cisco->new(host => $host);

        # Login to the device
        if (!$session->login($ssh_user, $ssh_pass)) {
            print("Login failed for $host\n");
            next;  # Skip to the next switch if login fails
        }

        # Enter enable mode
        if ($session->enable($enable_pass)) {
            print "Entered enable mode on $host.\n";
        } else {
            die "Failed to enter enable mode on $host: " . $session->errmsg;
        }

        # Enter configuration mode
        $session->cmd("conf t");

        # Shut down all interfaces on this switch
        foreach my $interface (@$interfaces_ref) {
            $session->cmd("interface $interface");
	    $session->cmd("shut");
            $session->cmd("exit");
            print "Interface $interface on $host has been shut down.\n";
            push @shut_interfaces, $interface;  # Track shut interfaces
        }

        # Exit configuration mode
        $session->cmd("end");

        # Close SSH connection
        $session->close();
        print "SSH session to $host closed after shutting down interfaces.\n";

        # Store shut actions
        $actions{$host}{shut} = \@shut_interfaces;
    }

    # Step 2: No shut all interfaces on all switches with a delay
    foreach my $host (@$switches_ref) {
        my @no_shut_interfaces;

        # Establish SSH connection again
        my $session = Net::SSH2::Cisco->new(host => $host);

        # Login to the device
        if (!$session->login($ssh_user, $ssh_pass)) {
            print("Login failed for $host\n");
            next;  # Skip to the next switch if login fails
        }

        # Enter enable mode
        if ($session->enable($enable_pass)) {
            print "Entered enable mode on $host.\n";
        } else {
            die "Failed to enter enable mode on $host: " . $session->errmsg;
        }

        # Enter configuration mode
        $session->cmd("conf t");

        # No shut interfaces with a delay of 10 seconds per interface
        foreach my $interface (@$interfaces_ref) {
            $session->cmd("interface $interface");
	    $session->cmd("no shut");
            $session->cmd("exit");

            print "Interface $interface on $host has been brought back up.\n";
            push @no_shut_interfaces, $interface;  # Track no shut interfaces
            sleep 10;  # Wait for 10 seconds before proceeding to the next interface
        }

        # Exit configuration mode
        $session->cmd("end");

        #/>  Close SSH connection
        $session->close();
        print "SSH session to $host closed after bringing interfaces back up.\n";

        # Store no shut actions
        $actions{$host}{no_shut} = \@no_shut_interfaces;
    }

    return \%actions;  # Return the actions performed
}



# Function to check uptime and send an alert if necessary
sub check_uptime {
    my ($host) = @_;

    # Perform SNMP walk to get uptime
    my $uptime_raw = `snmpwalk -v 2c -c $community $host $oid 2>/dev/null`;

    if ($? != 0) {
        print "SNMP walk failed for $host. Marking as unreachable.\n";
        $unreachable_count++;
        push @unreachable_devices, $host;
        $uptime_info{$host} = "Unreachable";
        return;
    }

    # Extract the timeticks value from the SNMP walk output
    my ($timeticks) = ($uptime_raw =~ /\((\d+)\)/);

    # Convert timeticks to minutes
    my $uptime_minutes = $timeticks / 100 / 60;

    # Save uptime information for daily report
    $uptime_info{$host} = format_uptime($uptime_minutes);






if ($uptime_minutes < 10) {
    print "Uptime is less than 10 minutes for $host. Executing SSH commands.\n";
    if (exists $device_interfaces{$host}) {
        # Execute SSH commands and capture the actions performed
        my $actions = execute_ssh_commands([$host], $device_interfaces{$host});  # Pass $host as an array reference

        # Prepare the email with details of the actions
        my $action_details = "Details of actions performed on $host:\n";
        foreach my $switch (keys %$actions) {
            $action_details .= "Switch: $switch\n";

            # Shut interfaces
            if (exists $actions->{$switch}{shut}) {
                $action_details .= "  Shut interfaces: " . join(', ', @{$actions->{$switch}{shut}}) . "\n";
            }

            # No shut interfaces
            if (exists $actions->{$switch}{no_shut}) {
                $action_details .= "  No shut interfaces: " . join(', ', @{$actions->{$switch}{no_shut}}) . "\n";
            }
        }

        # Send email with details
        send_email("SSH Actions Performed on $host", $action_details);
    } else {
        print "No interface configuration found for $host. Skipping SSH commands.\n";
    }
} else {
print "Uptime for $host is greater than 10 minutes. No alert needed.\n";
    }
}

# Function to execute the "show cdp neighbor details" command and parse the output
sub collect_cdp_info {
    my ($host) = @_;
    my @ap_info;

    # Establish SSH connection
    my $session = Net::SSH2::Cisco->new(
        host     => $host,
        user     => $ssh_user,
        password => $ssh_pass,
    );

    # Log in
    $session->login() or die "Login has failed.";

    # Enter enable mode
    if ($session->enable($enable_pass)) {
        print "Entered enable mode on $host.\n";
    } else {
        die "Failed to enter enable mode: " . $session->errmsg;
    }

    # Run the "show cdp neighbor detail" command
    my @output = $session->cmd('show cdp neighbor detail');

    # Split the output into blocks using the dashed lines
    my @blocks = split /-------------------------/, join('', @output);

    # Parse each block for Device ID and IP address
    foreach my $block (@blocks) {
        my ($device_id) = $block =~ /Device ID:\s+(\S+)/;
        my ($ip_address) = $block =~ /IP address:\s+(\d+\.\d+\.\d+\.\d+)/;

        if ($device_id && $ip_address) {
            push @ap_info, [$device_id, $ip_address];
        }
    }

    # Close the SSH connection
    $session->close();

    return @ap_info;
}

# Function to save the AP details to a CSV file
sub save_to_csv {
    my ($filename, @ap_info) = @_;

    my $csv = Text::CSV->new({ binary => 1, eol => $/ });
    open my $fh, ">", $filename or die "Could not open '$filename' $!\n";

    $csv->say($fh, ["AP Name", "IP Address"]);

    foreach my $row (@ap_info) {
        $csv->say($fh, $row);
    }

    close $fh or die "Could not close '$filename' $!\n";
}

# Function to send the daily test email
sub send_daily_test_email {
    my $current_date = strftime "%Y-%m-%d", localtime;

    # Subtract 86400 seconds (1 day) from the current time
    my $yesterday_time = time() - 86400;

    # Format the date
    my $yesterday_date = strftime "%Y-%m-%d", localtime($yesterday_time);

    print "Yesterday's date: $yesterday_date\n";
    my $csv_file = "/tmp/${yesterday_date}_AP_Details.csv";

    # Collect AP info from all devices
    #    my @all_ap_info;
    #    foreach my $host (@devices) {
    #        my @ap_info = collect_cdp_info($host);
    #        push @all_ap_info, @ap_info;
    #    }

    # Save to CSV
    #    save_to_csv($csv_file, @all_ap_info);

    # Prepare the email body
    my $body = "This is the daily test email. Below is the current uptime per device:\n\n";

    foreach my $host (@devices) {
        my $uptime_str = $uptime_info{$host} // "Not available";
        $body .= "$host: $uptime_str\n";
    }

    $body .= "\nAttached is the latest AP details collected from the devices.\n";

    # Send the email with the CSV attachment
    send_email($test_subject, $body, $csv_file);
}

# Main script execution

# Load the last email sent date
my $last_email_date;
if (-e $timestamp_file) {
    open my $fh, '<', $timestamp_file or die "Cannot open $timestamp_file: $!";
    chomp($last_email_date = <$fh>);
    close $fh;
}

# Get current date
my $current_date = strftime "%Y-%m-%d", localtime;

# Check uptime for each device
foreach my $device (@devices) {
    check_uptime($device);
}

# Check if a daily test email should be sent
if (defined $last_email_date) {
    if ($last_email_date ne $current_date) {
        send_daily_test_email();
    }
} else {
    send_daily_test_email();
}

# Save the current date as the last email sent date
open my $fh, '>', $timestamp_file or die "Cannot open $timestamp_file: $!";
print $fh $current_date;
close $fh;

# Check if any devices are unreachable and send an alert if necessary
if ($unreachable_count > 0) {
    my $body = "The following devices are not reachable:\n" . join("\n", @unreachable_devices);
    send_email($unreachable_subject, $body);
}
