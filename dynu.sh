#! /usr/bin/env sh
#
# dynu.com DDNS update program
# (C) 2023,2024 Attila Bruncsak
# Usage:
#  - argument "setip": updates the IPv4/IPv6 addresses of the configured domains in dynu.com
#  - argument "nsupdate": reads the nsupdate style commands on the standard input.
#  limited functionality: only "update add" and "update delete" implemented and only TXT type
#  the target is the implementation of the DNS-01 challenge type of the ACME protocol.
#  - argument "getdns": list the records of the zones. Does not include the IP address(es) of the apex.
#
# the date of the that version
VERSION_DATE="2024-12-22"

# The meaningful User-Agent to help finding related log entries in the dynu.com server log
USER_AGENT="dynu.sh/$VERSION_DATE (https://github.com/bruncsak/dynu.sh)"

log() {
  if [ "$1" -le "$LOGLEVEL" ] ;then
    shift
    printf '%s\n' "$*" >& 2
  fi
}

errmsg() {
  log 0 "$@"
}

infomsg() {
  log 1 "$@"
}

dbgmsg() {
  log 2 "$@"
}

err_exit() {
  errmsg "$@"
  exit 1
}

checknumber() {
  printf '%s\n' "$1" | grep -E -s -q -e '^-?[0-9]+$'
}

toupper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

tolower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

stricmp() {
  [ "`tolower $1`" = "`tolower $2`" ]
}


usage() {
  err_exit "Usage: $PROGNAME [-a API-Key] [-c configfile] [-d debuglevel] [-q] [-v] [-f] {nsupdate|getdns|setip}"
}

PROGNAME="`basename $0`"
LOGLEVEL=1
FORCE=false
CONFIG_DIR=$HOME/.config/dynu-update
CONFIG_FILE=$CONFIG_DIR/config
API_KEY=

# parse command line into arguments
TMP="`getopt a:c:d:qvf $*`"
# check result of parsing
if [ $? != 0 ]
then
  usage
fi
# evaluate the result of parsing
set -- $TMP
while [ $1 != -- ]
do
  case $1 in
  -a)  # set up the -a flag
       API_KEY="$2"
       shift;;
  -c)  # set up the -c flag
       CONFIG_FILE="$2"
       shift;;
  -d)  # set up the -d flag
       if checknumber $2 ;then
         LOGLEVEL="$2"
       else
         err_exit "Debuglevel argument must be a number: $2"
       fi
       shift;;
  -q)  # set up the -q flag (quiet)
       LOGLEVEL=0;;
  -v)  # set up the -v flag (verbose)
       LOGLEVEL=2;;
  -f)  # set up the -f flag (force)
       FORCE=true;;
  esac
  shift  # next flag
done
shift   # skip double dash

dbgmsg "Config file: $CONFIG_FILE"

if [[ "$CONFIG_FILE" = "$CONFIG_DIR/config" && ! -e "$CONFIG_FILE" && -z "$API_KEY" ]] ;then
    infomsg "Initializing config file template at $CONFIG_FILE, you must add the API-Key into that file."
    [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"
    cat << ! > "$CONFIG_FILE"
#   Please specify the API-Key via initializing
#   the API_KEY variable here in this config file.
#   You can pick up the value at dynu.com under
#   Control Panel / API Credentials.
API_KEY=
!
fi

[[ -e "$CONFIG_FILE" && -z "$API_KEY" ]] && . "$CONFIG_FILE"

if [ -z "$API_KEY" ] ;then
    err_exit "Undefined API_KEY, please specify in $CONFIG_FILE or as command line argument with the \"-a\" option"
fi

RESP_HEADER="`mktemp`"
RESP_BODY="`mktemp`"

trap "rm -f $RESP_HEADER $RESP_BODY; exit" 0 1 2 3 13 15

stripdot() {
  echo $domain_name | sed -e 's/\.*$//'
}

nodesplit() {
echo $1 $2 | awk '{
al = split($1, a, /\./); # get the nodename of that
bl = split($2, b, /\./); # reference
if (bl > al)
  print $1;
else
  {
  i = al;
  j = bl;
  while (j > 0 && i > 0 && tolower(a[i]) == tolower(b[j]))
    {
    i--;
    j--;
    }
  if (j == 0)
    {
    for (k = 1; k <= i; k++)
      {
      if (k != 1) printf(".");
      printf("%s", a[k]);
      }
    printf "\n";
    }
  else
    print $1
  }
}'
}

curl_return_text ()
{
    case "$1" in
        # see man curl "EXIT CODES"
         3) TXT=", malformed URI" ;;
         6) TXT=", could not resolve host" ;;
         7) TXT=", failed to connect" ;;
        28) TXT=", operation timeout" ;;
        35) TXT=", SSL connect error" ;;
        52) TXT=", the server did not reply anything" ;;
        56) TXT=", failure in receiving network data" ;;
        60) TXT=", peer certificate cannot be authenticated with known CA certificates" ;;
         *) TXT="" ;;
    esac
    printf "curl return status: %d%s" "$1" "$TXT"
}

curl_loop()
{
    CURL_ACTION="$1"; shift
    loop_count=0
    pluriel=""
    while : ;do
        dbgmsg "About making a web request to \"$CURL_ACTION\""
        curl "$@"
        CURL_RETURN_CODE="$?"
        [[ "$loop_count" -ge 20 ]] && break
        case "$CURL_RETURN_CODE" in
            6) ;;
            7) ;;
            28) ;;
            35) ;;
            52) ;;
            56) ;;
            *) break ;;
        esac
        (( loop_count += 1 ))
        dbgmsg "While making a web request to \"$CURL_ACTION\" sleeping $loop_count second$pluriel before retry due to `curl_return_text $CURL_RETURN_CODE`"
        sleep "$loop_count"
        pluriel="s"
    done
    if [ "$CURL_RETURN_CODE" -ne 0 ] ;then
        errmsg "While making a web request to \"$CURL_ACTION\" error exiting due to `curl_return_text $CURL_RETURN_CODE` (retry number: $loop_count)"
        exit "$CURL_RETURN_CODE"
    else
        dbgmsg "While making a web request to \"$CURL_ACTION\" continuing due to `curl_return_text $CURL_RETURN_CODE`"
    fi
}

local_ipv4() {
  ip -4 address show scope global |
  awk '$1 == "inet" {sub(/\/.*$/, "", $2); print $2}'
}

local_ipv6() {
  ip -6 address show scope global |
  awk '$1 == "inet6" {sub(/\/.*$/, "", $2); print $2}'
}

ipv4_echo() {
  case "$1" in
    ifconfigco)
      curl_loop "-s -4 -A \"$USER_AGENT\" 'http://ifconfig.co/ip'" -s -4 -A "$USER_AGENT" 'http://ifconfig.co/ip' ;;
    ifconfigme)
      curl_loop "-s -4 -A \"$USER_AGENT\" 'http://ifconfig.me/ip'" -s -4 -A "$USER_AGENT" 'http://ifconfig.me/ip' ;;
    ipechonet)
      curl_loop "-s -4 -A \"$USER_AGENT\" 'http://ipecho.net/plain'" -s -4 -A "$USER_AGENT" 'http://ipecho.net/plain' ;;
    dyndnscom)
      curl_loop "-s -A \"$USER_AGENT\" 'http://checkip.dyndns.com/'" -s -A "$USER_AGENT" 'http://checkip.dyndns.com/' | sed -e 's/^.*: *\([0-9.]*\).*$/\1/' ;;
  esac
}

ipv6_echo() {
  case "$1" in
    ifconfigco)
      curl_loop "-s -6 -A \"$USER_AGENT\" 'http://ifconfig.co/ip'" -s -6 -A "$USER_AGENT" 'http://ifconfig.co/ip' ;;
    ifconfigme)
      curl_loop "-s -6 -A \"$USER_AGENT\" 'http://ifconfig.me/ip'" -s -6 -A "$USER_AGENT" 'http://ifconfig.me/ip' ;;
    ipechonet)
      curl_loop "-s -6 -A \"$USER_AGENT\" 'http://ipecho.net/plain'" -s -6 -A "$USER_AGENT" 'http://ipecho.net/plain' ;;
  esac
}

get_ipv4() {
  IP_V4="null"
  LOCAL_IPV4="`local_ipv4`"
  dbgmsg "Local IPv4 address: $LOCAL_IPV4"
  if [ -n "$LOCAL_IPV4" ] ;then
    for IP_ECHO_SERVICE in ifconfigco ifconfigme ipechonet dyndnscom ;do
      IPV4="`ipv4_echo $IP_ECHO_SERVICE`"
      if printf '%s\n' "$IPV4" | grep -E -s -q -e '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ;then
        IP_V4="$IPV4"
        dbgmsg "The $IP_ECHO_SERVICE IPv4 echo service returned: $IPV4"
        [ "$LOGLEVEL" -le 2 ] && break
      else
        infomsg "Instead of an IP address, the $IP_ECHO_SERVICE IPv4 echo service returned: $IPV4"
      fi
    done
  fi
  printf '%s' "$IP_V4"
}

get_ipv6() {
  IP_V6="null"
  LOCAL_IPV6="`local_ipv6`"
  dbgmsg "Local IPv6 address: $LOCAL_IPV6"
  if [ -n "$LOCAL_IPV6" ] ;then
    for IP_ECHO_SERVICE in ifconfigco ifconfigme ipechonet ;do
      IPV6="`ipv6_echo $IP_ECHO_SERVICE`"
      if printf '%s\n' "$IPV6" | grep -E -s -q -e '^[0-9a-f:]+$' ;then
        IP_V6="$IPV6"
        dbgmsg "The $IP_ECHO_SERVICE IPv6 echo service returned: $IPV6"
        [ "$LOGLEVEL" -le 2 ] && break
      else
        infomsg "Instead of an IP address, the $IP_ECHO_SERVICE IPv6 echo service returned: $IPV6"
      fi
    done
  fi
  printf '%s' "$IP_V6"
}

dns_update_data() {
    grep -E -v '^[ 	]*(#|$)' << ! |
{
   "name": "$name"
# ,"group": ""
  ,"ipv4Address": "`get_ipv4`"
# ,"ipv6Address": "1111:2222:3333::4444"
# ,"ttl": 90
# ,"ipv4": true
# ,"ipv6": false
# ,"ipv4WildcardAlias": false
# ,"ipv6WildcardAlias": false
# ,"allowZoneTransfer": false
# ,"dnssec": false
}
!
tr -d ' \r\n'
}

dequote_double()
{
    printf '%s' "$1" | sed -e 's/\\"/"/g'
}

get_array_value() {
    tr -d '\r\n' < "$RESP_BODY" | sed -e 's/^.*"'"$1"'":\[\([^]]*\)\].*$/\1/'
}

get_status_code() {
    tr -d '\r\n' < "$RESP_BODY" | sed -e 's/^.*"statusCode":\([0-9]*\).*$/\1/'
}

get_domain_list() {
    tr -d '\r\n' < "$RESP_BODY" | sed -e 's/^.*"domains":\[\([^]]*\)\].*$/\1/'
}

get_first_domain() {
    [ -z "$2" ] || errmsg "Not one argument in get_first_domain: $*"
    printf '%s' "$1" | sed -e 's/^[^{]*{\([^}]*\)}.*$/\1/'
}

get_next_domains() {
    [ -z "$2" ] || errmsg "Not one argument in get_next_domain: $*"
    printf '%s' "$1" | sed -e 's/^[^{]*{[^}]*}\(.*\)$/\1/'
}

get_value() {
    [ -z "$3" ] || errmsg "Not two arguments in get_value: $*"
    printf '%s' "$2" | sed -r -e 's/^.*"'"$1"'":"{0,1}((\\"|[^"])*)"{0,1}([,}].*)?$/\1/'
}

API_status_check() {
status_code="`get_status_code`"
if [ "$status_code" != "200" ] ;then
    errmsg "Request of: $1"
    if [ -n "$2" ] ; then
        errmsg "with the following post data: $2"
        errmsg
    fi
    cat "$RESP_BODY" >& 2
    err_exit
fi
}

curl_delete() {
    dbgmsg "curl DELETE, URL: $1"
    curl_loop "DELETE $1" -s -A "$USER_AGENT" -X DELETE  "$1" -H "accept: application/json" -H  "API-Key: $API_KEY" -D "$RESP_HEADER" -o "$RESP_BODY"
    dbgmsg "curl DELETE, output: `cat $RESP_BODY`"
    API_status_check "$1"
}

curl_get() {
    dbgmsg "curl GET, URL: $1"
    curl_loop "GET $1" -s -A "$USER_AGENT" -X GET  "$1" -H "accept: application/json" -H  "API-Key: $API_KEY" -D "$RESP_HEADER" -o "$RESP_BODY"
    dbgmsg "curl GET, output: `cat $RESP_BODY`"
    API_status_check "$1"
}

curl_post() {
    dbgmsg "curl POST, URL: $1"
    dbgmsg "curl POST, input: $2"
    curl_loop "POST $1" -s -A "$USER_AGENT" -X POST "$1" -H "accept: application/json" -H  "API-Key: $API_KEY" -D "$RESP_HEADER" -o "$RESP_BODY" -d "$2"
    dbgmsg "curl POST, output: `cat $RESP_BODY`"
    API_status_check "$1" "$2"
}

setip_action() {
  act_ipv4Address="`get_ipv4`"
  act_ipv6Address="`get_ipv6`"
  curl_get "https://api.dynu.com/v2/dns"
  domain_list="`get_domain_list`"
  dbgmsg "domain list: $domain_list"
  while [ -n "$domain_list" ] ;do
    domain="`get_first_domain $domain_list`"
    dbgmsg "domain: $domain"
    id="`get_value id $domain`"
    name="`get_value name $domain`"
    group="`get_value group $domain`"
    ttl="`get_value ttl $domain`"
    ipv4="`get_value ipv4 $domain`"
    ipv6="`get_value ipv6 $domain`"
    ipv4WildcardAlias="`get_value ipv4WildcardAlias $domain`"
    ipv6WildcardAlias="`get_value ipv6WildcardAlias $domain`"
    ipv4Address="`get_value ipv4Address $domain`"
    ipv6Address="`get_value ipv6Address $domain`"
    new_ipv4Address="$act_ipv4Address"
    new_ipv6Address="$act_ipv6Address"
    if [ "$ipv4Address" != "$new_ipv4Address" ] || [ "$ipv6Address" != "$new_ipv6Address" ] || $FORCE ;then
      dbgmsg "name: $name; id: $id; ipv4Address: $ipv4Address -> $new_ipv4Address; ipv6Address: $ipv6Address -> $new_ipv6Address;"
      if [ "$new_ipv4Address" != "null" ] ;then
        new_ipv4Address="\"$new_ipv4Address\""
        ipv4=true
      else
        ipv4=false
      fi
      if [ "$new_ipv6Address" != "null" ] ;then
        new_ipv6Address="\"$new_ipv6Address\""
        ipv6=true
      else
        ipv6=false
      fi
      curl_post "https://api.dynu.com/v2/dns/$id" "{\"name\":\"$name\",\"group\":\"$group\",\"ipv4Address\":$new_ipv4Address,\"ipv6Address\":$new_ipv6Address,\"ttl\":$ttl,\"ipv4\":$ipv4,\"ipv6\":$ipv6,\"ipv4WildcardAlias\":$ipv4WildcardAlias,\"ipv6WildcardAlias\":$ipv6WildcardAlias}"
    fi
    # curl_post "https://api.dynu.com/v2/dns/$id" "`dns_update_data`"
    domain_list="`get_next_domains $domain_list`"
  done
}

nsupdate_action() {
  # RFC2136
  while read action direction domain_name ttl class rec_type value
  do
    dbgmsg "value: $value"
    value="`printf '%s' "$value" | sed -e 's/^"\(.*\)"$/\1/'`"
    dbgmsg "value: $value"
    if ! stricmp "$action" update ;then
      errmsg "Unsupported nsupdate action: $action"
      continue
    fi
    if ! stricmp "$direction" add && ! stricmp "$direction" delete ;then
      errmsg "Unsupported nsupdate direction: $direction"
      continue
    fi
    if ! stricmp "$class" "in" ;then
      errmsg "Unsupported nsupdate class: $class"
      continue
    fi
    if ! stricmp "$rec_type" txt ;then
      errmsg "Unsupported nsupdate record type: $rec_type"
      continue
    fi
    if ! checknumber "$ttl" ;then
      errmsg "TTL value must be a number: $ttl"
      continue
    fi
    domain_name="`stripdot $domain_name`"
    curl_get "https://api.dynu.com/v2/dns"
    domain_list="`get_domain_list`"
    dbgmsg "domain list: $domain_list"
    while [ -n "$domain_list" ] ;do
      domain="`get_first_domain $domain_list`"
      dbgmsg "domain: $domain"
      domainId="`get_value id $domain`"
      name="`get_value name $domain`"
      node="`nodesplit $domain_name $name`"
      if [ "$node" != "$domain_name" ] ;then
        dbgmsg "updating $domain_name with node $node"
        if stricmp "$direction" delete ;then
          curl_get "https://api.dynu.com/v2/dns/$domainId/record"
          dnsrecords="`get_array_value dnsRecords`"
          dbgmsg "dns records array: $dnsrecords"
          while [ -n "$dnsrecords" ] ;do
            dnsrecord="`get_first_domain "$dnsrecords"`"
            dbgmsg "dnsrecord: $dnsrecord"
            hostname="`get_value hostname "$dnsrecord"`"
            dbgmsg "hostname: $hostname"
            recordType="`get_value recordType "$dnsrecord"`"
            dbgmsg "recordType: $recordType"
            if stricmp "$recordType" "$rec_type" ;then
              textData="`get_value textData "$dnsrecord"`"
              dbgmsg "textData: $textData"
          if [ -z "$value" ] || [ "$value" == "$textData" ] ;then
            hostId="`get_value id "$dnsrecord"`"
                curl_delete "https://api.dynu.com/v2/dns/$domainId/record/$hostId"
          else
        dbgmsg value \"$value\" is not equal to \"$textData\" or \"$value\" is not empty.
          fi
        else
              dbgmsg record type $recordType does not match $rec_type
            fi
            dnsrecords="`get_next_domains "$dnsrecords"`"
          done
        elif stricmp "$direction" add ;then
          curl_post "https://api.dynu.com/v2/dns/$domainId/record" "{\"nodeName\":\"$node\",\"recordType\":\"`toupper "$rec_type"`\",\"ttl\":$ttl,\"state\":true,\"group\":\"\",\"textData\":\"$value\"}"
        else
      errmsg unsupported direction: "$direction"
    fi
    break
      fi
      domain_list="`get_next_domains $domain_list`"
    done
  done
}

getdns_action() {
    curl_get "https://api.dynu.com/v2/dns"
    domain_list="`get_domain_list`"
    dbgmsg "domain list: $domain_list"
    while [ -n "$domain_list" ] ;do
      domain="`get_first_domain $domain_list`"
      dbgmsg "domain: $domain"
      domainId="`get_value id $domain`"
      name="`get_value name $domain`"
      node="`nodesplit $domain_name $name`"
      curl_get "https://api.dynu.com/v2/dns/$domainId/record"
      dnsrecords="`get_array_value dnsRecords`"
      dbgmsg "dns records array: $dnsrecords"
      while [ -n "$dnsrecords" ] ;do
        dnsrecord="`get_first_domain "$dnsrecords"`"
        dbgmsg "dnsrecord: $dnsrecord"
        content="`get_value content "$dnsrecord"`"
        content="`dequote_double "$content"`"
        printf '%s\n' "$content"
        dnsrecords="`get_next_domains "$dnsrecords"`"
      done
      domain_list="`get_next_domains $domain_list`"
    done
}

case "$1" in
  "")
    usage
    ;;
  setip|nsupdate|getdns)
    dbgmsg "$1 action"
    "$1"_action
    ;;
  *)
    err_exit "Unknown action: $1"
    ;;
esac

exit

dns_record_add_data() {
    grep -E -v '^[ 	]*(#|$)' << ! |
{
  "nodeName": "_acme-challenge",
  "recordType": "TXT",
  "ttl": 300,
  "state": true,
  "group": "",
  "textData": "abcd"
}
!
tr -d ' \r\n'
}
curl_post "https://api.dynu.com/v2/dns/$id/record" "`dns_record_add_data`"

exit
