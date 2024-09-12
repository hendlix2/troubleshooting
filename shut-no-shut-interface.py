import paramiko
import time
import json
from datetime import datetime

# Define the login credentials
username = 'user'
password = 'password'

def load_config(filename):
    """Load switch configurations from a JSON file."""
    with open(filename, mode='r') as file:
        config = json.load(file)
    return config

def run_command(remote_conn, command):
    """Send a command to the switch and wait for it to complete."""
    remote_conn.send(command + '\n')
    time.sleep(1)  # Give time for the command to process

def login_and_configure_switch(switch_ip, interfaces, action='shutdown'):
    """Login to the switch and either shut down or enable the interfaces."""
    print(f"Connecting to switch {switch_ip}...")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        ssh.connect(switch_ip, username=username, password=password, look_for_keys=False, allow_agent=False)
        remote_conn = ssh.invoke_shell()

        # Enter enable mode
        run_command(remote_conn, 'enable')
        run_command(remote_conn, 'config t')

        # Execute action (shutdown or no shutdown) on interfaces
        for interface in interfaces:
            if action == 'shutdown':
                print(f"Shutting down interface {interface} on {switch_ip}")
                run_command(remote_conn, f"interface {interface}")
                run_command(remote_conn, "shutdown")
            elif action == 'no shutdown':
                print(f"Bringing up interface {interface} on {switch_ip}")
                run_command(remote_conn, f"interface {interface}")
                run_command(remote_conn, "no shutdown")
                time.sleep(10)  # Wait 10 seconds between each interface

        action_message = "shut down" if action == 'shutdown' else "re-enabled"
        print(f"All interfaces on {switch_ip} have been {action_message}.")

    except Exception as e:
        print(f"Failed to configure the switch {switch_ip}: {str(e)}")

    finally:
        ssh.close()
        print(f"Disconnected from switch {switch_ip}\n")

def main():
    # Load the switch and interface configurations
    config = load_config('switch_interfaces.json')

    # Stage 1: Shut down all interfaces on all switches
    print("Starting Stage 1: Shutting down all interfaces on all switches.")
    for switch in config['switches']:
        switch_ip = switch['ip']
        interfaces = switch['interfaces']
        login_and_configure_switch(switch_ip, interfaces, action='shutdown')

    # Stage 2: Bring up all interfaces with a delay on all switches
    print("Starting Stage 2: Bringing up all interfaces with a delay.")
    for switch in config['switches']:
        switch_ip = switch['ip']
        interfaces = switch['interfaces']
        login_and_configure_switch(switch_ip, interfaces, action='no shutdown')

if __name__ == '__main__':
    main()
