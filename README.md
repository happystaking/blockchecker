# blockchecker.sh

This script is meant to be run periodically on your BP and standby BP(s). It searches for forged blocks and then connects to your relays via SSH to find the propagation time for the block from the BP to that relay. Furthermore it connects to PoolTool.io to check propagation time and also checks there for slot/height battles. All results are stored in a PostgreSQL database to allow further analysis and reporting.

## Prerequisites
You need SSH on all your nodes and a PostgreSQL server on a remote or local system. If you are using PostgreSQL on a remote system, then you will need the PostgreSQL client packages on the local system.

The script will SSH into your relays and execute the command `sudo journalctl`. In order for this to succeed a user needs to have SSH access to the relays and must be able to run sudo without having to enter a password. The credentials can be set up in the `.blockchecker.config` file. Make sure that this user can SSH into all the relays from the BP without having to enter a password/passphrase and that the user can execute the `journalctl` command to see the `cardano-node` log entries. From a security perspective you might want to set up a new and restricted user on your relays for this purpose.

## Installation
### Step 1
Copy the file `.blockchecker.config` to your home directory or any other folder. Open the file and enter your configuration and environment variables. Also enter the systemd service names cardano-node runs under. The `sudoPassword` variable applies to the sudo password on your relays. Leave empty if no password is required. Finally `chmod 0600` this file.

### Step 2
We need to have a PostgreSQL database running locally or remotely and the user running the script needs access to this database. You can use the provided `.blockchecker.pgpass` file where you enter the credentials to access the database. Set the shell environment variable `PGHOST` to where ever your database server is located if it's not a local server and set `PGDATABASE` to `blockchecker`. After you've edited the file copy it to a location of your choosing. Also `chmod 0600` this file.

Then create a database called `blockchecker` on your database server and test your connection from the BP by entering `psql -h <host> -U <user> -d blockchecker -c 'select version()'` as the user that'll run the script.

### Step 3
When the database is created and accessible you can define the schema. First edit the file `database/schema-data.sql` and enter the hostnames of all your relays. Make sure your relays are accessible via SSH using those hostnames. Test it for every relay by running `ssh <hostname>` as the user that'll run the script and accept the SSH fingerprints. Now import the schema:
```
psql -d blockchecker < database/schema-up.sql && \
psql -d blockchecker < database/schema-data.sql
```

### Step 4
Open `systemd/blockchecker.service` and edit the `ExecStart=` line to point the script to the location of your `.blockchecker.config` file. Optionally you may edit the search interval (default 4 hours), but then you'll also have to edit the `systemd.timer` file to match the interval.

Finally, set up the script for use with systemd:
```
sudo cp blockchecker.sh /usr/local/bin/ && \
sudo cp systemd/blockchecker.{timer,service} /etc/systemd/system && \
sudo systemctl enable --now blockchecker.timer
```
This will run the script every four hours to check for blocks made in the past four hours (+10 minutes to account for search delays). You can always manually run the script using a larger timeframe using `blockchecker.sh <path to .blockchecker.config> 24h`. Existing blocks in the database will be updated.

## Contributing
If you have improvements to the script, please open a pull request. If you find this script useful and you want to show it, you can send some ADA, tokens or NFT's to `$happystaking`.

Special thanks to PoolTool.io for for providing a great service and for my request to add valuable information to their JSON output. Check out the 1LOVE pool if you want to show them some support.