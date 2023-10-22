# dynu.sh
Dynamic DNS update program for `dynu.com`
- updates the IPv4 and IPv6 address of your domain(s) hosted on dynu.com
- `nsupdate` (RFC2136) kind interface to update DNS TXT records. So it can be used as `DNS-01` plugin for ACME clients:

  `update add _acme-challenge.mydomain.mywire.com 60 IN TXT "abcd-efgh_ijkl"`
- lists the content of the zone files
