#!/usr/bin/perl

use strict;
use warnings;
use POSIX qw(strftime);
use MIME::Lite;
use Net::SSH::Expect;
use Text::CSV;

# SNMP details
my $community = "ks2020rm";
my $oid = "iso.3.6.1.2.1.1.3.0";

# Email details
my $sender = 'peter.hendlinger@karcher.com';
my @recipients = (
    'user1@domain.com',
    'user2@domain.com',
);
my $subject = "Alert: Device Uptime Less Than 10 Minutes";
my $test_subject = "Daily Test Email: Device Uptime Check";
my $unreachable_subject = "Alert: Multiple Devices Not Reachable";

# List of devices (IP addresses or hostnames)
my @devices = (
    "1.1.1.1",
    "2.2.2.2",
    # Add more devices as needed
);

# SSH details for the switches
my $ssh_user = "username";
my $ssh_pass = "password";
my $enable_pass = "enable_password";

# Hash to store the interfaces per device
my %device_interfaces = (
    "10.84.13.9" => ["Gig4/0/48","Gig4/0/47","Gig4/0/46","Gig4/0/45","Gig4/0/44","Gig4/0/43","Gig4/0/42","Gig4/0/41","Gig3/0/48","Gig3/0/47","Gig3/0/46","Gig3/0/45","Gig3/0/44","Gig3/0/43","Gig3/0/42","Gig3/0/41","Gig2/0/48","Gig2/0/47","Gig2/0/46","Gig2/0/45","Gig2/0/44","Gig2/0/43","Gig2/0/42","Gig2/0/41"],
    "10.84.13.10" => ["Gig2/0/48","Gig2/0/47","Gig2/0/46","Gig2/0/45","Gig2/0/44","Gig2/0/43","Gig2/0/42","Gig2/0/41","Gig1/0/45","Gig1/0/44","Gig1/0/43","Gig1/0/42","Gig1/0/41",],
    "10.84.13.11" => ["Gig2/0/48","Gig2/0/46","Gig2/0/45","Gig1/0/48","Gig1/0/47","Gig1/0/46","Gig1/0/45","Gig1/0/44","Gig1/0/43",],
        "10.84.13.12" => ["Gig2/0/48 ", "Gig1/0/47", "Gig1/0/48", "Gig2/0/47"],
    # Add more devices and their interfaces as needed
);

# Timestamp file to track the last daily email sent date
my $timestamp_file = "/tmp/last_email_sent_date2.txt";

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

# Function to execute SSH commands to shut/no-shut interfaces
sub execute_ssh_commands {
    my ($host, $interfaces_ref) = @_;

    my $ssh = Net::SSH::Expect->new (
        host => $host,
        user => $ssh_user,
        password => $ssh_pass,
        raw_pty => 1,
        timeout => 10,
    );

    # Log in
    my $login_output = $ssh->login();
    if ($login_output !~ /#/) {
        die "Login has failed. Login output was: $login_output";
    }

    # Enter enable mode
    $ssh->send("enable");
    my $enable_output = $ssh->waitfor('Password:', 1);
    if ($enable_output) {
        $ssh->send($enable_pass);
        $ssh->waitfor('#', 1) or die "Failed to enter enable mode.";
    }

    # Enter configuration mode
    $ssh->send("conf t");
    $ssh->waitfor('#', 1) or die "Could not enter configuration mode.";

    # Shut interfaces
    foreach my $interface (@$interfaces_ref) {
        $ssh->send("interface $interface");
        $ssh->waitfor('#', 1) or die "Could not select interface $interface.";

        $ssh->send("shut");
        $ssh->waitfor('#', 1) or die "Could not shut interface $interface.";

        $ssh->send("exit");
        $ssh->waitfor('#', 1) or die "Could not exit interface mode.";
    }

    # No shut interfaces with a delay
    foreach my $interface (@$interfaces_ref) {
        $ssh->send("interface $interface");
        $ssh->waitfor('#', 1) or die "Could not select interface $interface.";

        $ssh->send("no shut");
        $ssh->waitfor('#', 1) or die "Could not no-shut interface $interface.";

        $ssh->send("exit");
        $ssh->waitfor('#', 1) or die "Could not exit interface mode.";

        print "Interface $interface on $host has been restarted.\n";
        sleep 5; # Wait for 5 seconds before proceeding to the next interface
    }

    # Exit configuration mode
    $ssh->send("end");
    $ssh->waitfor('#', 1) or die "Could not exit configuration mode.";

    # Close SSH connection
    $ssh->close();
    print "SSH session to $host closed.\n";
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

    # Check if uptime is less than 10 minutes
    if ($uptime_minutes < 10) {
        # Prepare email body
        my $body = "The device at $host has an uptime of $uptime_minutes minutes, which is less than the 10 minutes threshold.";
        send_email($subject, $body);

        # If uptime is less than 5 minutes, perform SSH actions
        if ($uptime_minutes < 5) {
            print "Uptime is less than 5 minutes for $host. Executing SSH commands.\n";
            if (exists $device_interfaces{$host}) {
                execute_ssh_commands($host, $device_interfaces{$host});
            } else {
                print "No interface configuration found for $host. Skipping SSH commands.\n";
            }
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
my $ssh = Net::SSH::Expect->new (
        host => $host,
        user => $ssh_user,
        password => $ssh_pass,
        raw_pty => 1,
        timeout => 10,
    );

    # Log in
    my $login_output = $ssh->login();
    if ($login_output !~ />/) {
        die "Login has failed. Login output was: $login_output";
    }

    # Enter enable mode
    $ssh->send("enable");
    my $enable_output = $ssh->waitfor('Password:', 1);
    if ($enable_output) {
        $ssh->send($enable_pass);
        $ssh->waitfor('#', 1) or die "Failed to enter enable mode.";
    }

    # Run the "show cdp neighbor detail" command
    $ssh->send("show cdp neighbor detail");
    my $output = $ssh->waitfor('#', 1);

    # Split the output into blocks using the dashed lines
    my @blocks = split /-------------------------/, $output;

    # Parse each block for Device ID and IP address
    foreach my $block (@blocks) {
        my ($device_id) = $block =~ /Device ID:\s+(\S+)/;
        my ($ip_address) = $block =~ /IP address:\s+(\d+\.\d+\.\d+\.\d+)/;

        if ($device_id && $ip_address) {
            push @ap_info, [$device_id, $ip_address];
        }
    }

    # Close the SSH connection
    $ssh->close();

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


# Subtrahiere 86400 Sekunden (1 Tag) von der aktuellen Zeit
    my $yesterday_time = time() - 86400;

# Formatierung des Datums
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
