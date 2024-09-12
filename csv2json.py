import csv
import json

def csv_to_json(csv_filename, json_filename):
    """Convert CSV to JSON format with IPs and interfaces."""
    switches = {}

    # Read the CSV file
    with open(csv_filename, mode='r') as csv_file:
        csv_reader = csv.DictReader(csv_file)

        # For each row, append interfaces to the corresponding Switch IP
        for row in csv_reader:
            ip = row['Switch IP']
            interface = row['Interface']

            if ip not in switches:
                switches[ip] = []
            switches[ip].append(interface)

    # Convert the structure to a list of dictionaries
    switch_list = [{'ip': ip, 'interfaces': interfaces} for ip, interfaces in switches.items()]

    # Write to the JSON file
    with open(json_filename, 'w') as json_file:
        json.dump({'switches': switch_list}, json_file, indent=4)

    print(f"CSV file {csv_filename} has been successfully converted to {json_filename}.")

if __name__ == '__main__':
    csv_filename = '/tmp/2024-09-05_AP_Details.csv'  # Replace with your actual CSV file path
    json_filename = 'switch_interfaces.json'  # Output JSON file
    csv_to_json(csv_filename, json_filename)
