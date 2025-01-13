# blockchecker.sh

This script is meant to be run periodically on your main core node and standby core node(s) to find forged blocks in the journal. When a block is found it connects to your relay(s) using Ansible to find the the block in their journal so the propagation time can be determined. Furthermore it connects to PoolTool.io to check the propagation time and also checks there for slot/height battles. All results are stored in a (local) PostgreSQL database to allow further analysis and reporting.

## Prerequisites
You need Ansible to SSH into your nodes and you need a PostgreSQL server on a remote or local system. If you are using PostgreSQL on a remote system you will only need the PostgreSQL client packages on the local system. The system(s) running the script also need the `yq` and `jq` binaries.

The script uses Ansible to SSH into your relays and execute the `journalctl` command. Set up your Ansible user and credentials using the files in the `ansible` directory. Specify your hosts (relays), a user/pass and optionally use an Ansible vault to store passwords encrypted.

To install all dependencies on a Debian system:
```
sudo apt install --no-install-recommends -y yq jq ansible postgresql-client
```

## Installation
### Step 1
Copy `.blockchecker` to your home directory. Open the `config` file in this directory and enter your configuration and environment variables.

If you want to be notified about slot/height battles then fill in an email address under `notifyEmailAddress=` and choose one of `none`, `slot`, `height` or `both` for `notifySlotBattle=` and `notifyHeightBattle=`.

Also enter the systemd service names cardano-node runs under for both `relayServiceName` and `coreServiceName`.

Set your PostgreSQL credentials in `pgpass` and set a password for the Ansible vault in `vtpass`.

### Step 2
Copy the `ansible/` directory to `/etc`, define your hosts (relays) in `inventory.yml` and set the become pass for each host in the `[relay]/bc_become_pass` file:
```
ansible_become_pass: topSecret
```

Encrypt these files with the password you defined in `vtpass` using the command:
```
sudo ansible-vault encrypt /etc/ansible/host_vars/[relay]/bc_become_pass
```

Make sure your relays are accessible from the core using SSH. Test it for every relay by running `ssh <hostname>` as the user that'll run the script and accept the SSH fingerprints.

### Step 3
Set the shell environment variable `PGHOST` to where ever your database server is located if it's not a local server and set `PGDATABASE` to `blockchecker`. After you've edited the file copy it to a location of your choosing. Also `chmod 0600` this file.

Then create a database called `blockchecker` on your database server and test your connection from the core by entering `psql -h <host> -U <user> -d blockchecker -c 'select version()'` as the user that'll run the script.

When the database is created and accessible you can define the schema:
```
psql -d blockchecker < database/schema-up.sql
```

### Step 4
Open `systemd/blockchecker.service`, set the path to your `pgpass` in `Environment=` and edit the `ExecStart=` line to point the script to the location of your `.blockchecker/config` file. Optionally you may edit the search interval (default 4 hours), but then you'll also have to edit the `systemd.timer` file to match the interval.

## Testing
Run the following command to test connectivity to your relay nodes and the database:
```
sudo /usr/local/bin/blockchecker.sh /path/to/.blockchecker/config test
```
If successful, it will output your PostgreSQL database version and a "SUCCESS" message for every of your relays indicating Ansible connected successfully.

## Enabling
Finally, set up the script for use with systemd. From the `~/blockchecker` directory run:
```
sudo cp blockchecker.sh /usr/local/bin/ && \
sudo cp systemd/blockchecker.{timer,service} /etc/systemd/system && \
sudo systemctl enable --now blockchecker.timer
```
This will run the script every four hours to check for blocks made in the past four hours (+10 minutes to account for search delays). You can always manually run the script using a larger timeframe using `blockchecker.sh <path to .blockchecker/config> 24h`. Blocks already existing in the database will be updated.

## Contributing
If you have improvements to the script, please open a pull request. If you find this script useful then please consider delegating to ticker HAPPY.

Special thanks to PoolTool.io for for providing a great service and for my request to add additional information to their JSON output. Check out the 1LOVE pool if you want to show them some support.