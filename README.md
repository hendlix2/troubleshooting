This is a set of scripts which are developed for troubleshooting and automatic resolution

The background is that after a power outage the AP's  get not all an ip address. What ever is the reason for. Only if one by one gets up all Cisco AP get an ip address.

there for the scripts have several steps:

script checks  every 5 min the uptime of each switch. As long this is over 10 min nothing will happen beside sending out a test email once a day.
if multiple devices are not reachable anymore, an email will be sent out for notification.
in case the switches are reachble again, and the uptime is less than 10 min the script will start a python script to shut down all ports where a AP is connected and bring them up with an delay of 10 seconds.
