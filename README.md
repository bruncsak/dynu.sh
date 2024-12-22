# dynu.sh
Update/management program for `dynu.com` dynamic DNS provider (simmilar to `No-ip`, `duckdns`).

Features of the program:
- updates the IPv4 and IPv6 address of your domain(s) hosted on dynu.com
- `nsupdate` (RFC2136) kind interface to update DNS TXT records. So it can be used as `DNS-01` plugin for ACME clients:

  `update add _acme-challenge.mydomain.mywire.com 60 IN TXT "abcd-efgh_ijkl"`
- lists the content of the zone files

### Installation/configuration
Prerequisite for the use of this program to be executed on the `dynu.com` web site:
1. create an account, a free one is just fine
2. select your domain name
3. get the API-Key from the web site available under "Control Panel/API Credentials", you have to put this into the configuration file later

Next steps on your system:

4. download the program
5. run the program (no need to run as root), that will initialize a default configuration file
6. edit the configuration file, add the API-Key into it
7. run the program with the `setip` argument
8. optionally and preferably, you may want to schedule its regular run via crontab

### Troubleshooting
Running the program without arguments gives a short usage instruction.
If you have any problem, try first to run with the `-d 2` option. Then, please do not hesitate to open an issue!
