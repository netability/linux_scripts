#!/usr/bin/env sh
# shellcheck disable=SC2034

dns_rrpproxy_info='CentralNic Reseller (RRPproxy) KeyDNS
Site: rrpproxy.net
Docs: KeyDNS ModifyDNSZone / StatusDNSZone via the HTTPS API
Options:
 RRP_User   API username (use a subuser scoped to Dns read/write/delete)
 RRP_Pass   API password
 RRP_Api    API endpoint (optional, defaults to the live endpoint)
Notes:
 - The zone must be hosted on KeyDNS (domain delegated to *.rrpproxy.net
   or *.dnsres.net) AND belong to the account these credentials own.
 - KeyDNS requires TXT rdata wrapped in double quotes.
 - Deletion requires the EXACT record line that was added, so add and
   remove build the line the same way.
 - OT&E (api-ote.rrpproxy.net) is a separate platform with its own
   accounts; production credentials will fail there.
'

RRP_Api_Default="https://api.rrpproxy.net/api/call.cgi"

########  Public functions #####################

# Usage: dns_rrpproxy_add _acme-challenge.www.example.com "TXT-VALUE"
dns_rrpproxy_add() {
  fulldomain=$1
  txtvalue=$2

  if ! _rrp_init; then
    return 1
  fi

  _info "Using CentralNic/RRPproxy KeyDNS"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  if ! _get_root "$fulldomain"; then
    _err "No KeyDNS zone found for '$fulldomain'."
    _err "Check the domain is hosted on KeyDNS and belongs to this account."
    return 1
  fi
  _debug _zone "$_zone"
  _debug _sub_domain "$_sub_domain"

  _rrp_record_line "$_sub_domain" "$txtvalue"
  _debug record_line "$_record_line"

  if _rrp_rest "ModifyDNSZone" "dnszone=$(printf "%s" "$_zone" | _url_encode)&addrr0=$(printf "%s" "$_record_line" | _url_encode)"; then
    _info "TXT record added."
    return 0
  fi

  _err "Failed to add the TXT record."
  _err "$response"
  return 1
}

# Usage: dns_rrpproxy_rm _acme-challenge.www.example.com "TXT-VALUE"
dns_rrpproxy_rm() {
  fulldomain=$1
  txtvalue=$2

  if ! _rrp_init; then
    return 1
  fi

  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  if ! _get_root "$fulldomain"; then
    _err "No KeyDNS zone found for '$fulldomain'."
    return 1
  fi

  _rrp_record_line "$_sub_domain" "$txtvalue"
  _debug record_line "$_record_line"

  if _rrp_rest "ModifyDNSZone" "dnszone=$(printf "%s" "$_zone" | _url_encode)&delrr0=$(printf "%s" "$_record_line" | _url_encode)"; then
    _info "TXT record removed."
    return 0
  fi

  # Cleanup failure must not fail a successful issuance - warn instead.
  _info "Warning: could not remove the TXT record. Remove it manually:"
  _info "  zone: $_zone   record: $_record_line"
  return 0
}

####################  Private functions ##################################

_rrp_init() {
  RRP_User="${RRP_User:-$(_readaccountconf_mutable RRP_User)}"
  RRP_Pass="${RRP_Pass:-$(_readaccountconf_mutable RRP_Pass)}"
  RRP_Api="${RRP_Api:-$(_readaccountconf_mutable RRP_Api)}"

  if [ -z "$RRP_Api" ]; then
    RRP_Api="$RRP_Api_Default"
  fi

  if [ -z "$RRP_User" ] || [ -z "$RRP_Pass" ]; then
    RRP_User=""
    RRP_Pass=""
    _err "CentralNic/RRPproxy credentials are not set."
    _err "export RRP_User=\"account:subuser\""
    _err "export RRP_Pass=\"password\""
    return 1
  fi

  _saveaccountconf_mutable RRP_User "$RRP_User"
  _saveaccountconf_mutable RRP_Pass "$RRP_Pass"
  if [ "$RRP_Api" != "$RRP_Api_Default" ]; then
    _saveaccountconf_mutable RRP_Api "$RRP_Api"
  fi
  return 0
}

# Build the KeyDNS record line. Single source of truth so that the line
# passed to delrr0 matches byte-for-byte what addrr0 created.
# Usage: _rrp_record_line <relative-name> <txt-value>  -> sets _record_line
_rrp_record_line() {
  _rl_name=$1
  _rl_value=$2
  _record_line="$_rl_name IN TXT \"$_rl_value\""
}

# Call the API. Credentials go in the POST body, never the query string,
# so they stay out of proxy logs and shell history.
# Usage: _rrp_rest <command> [extra-params]
_rrp_rest() {
  _rrp_cmd=$1
  _rrp_extra=$2

  _rrp_body="s_login=$(printf "%s" "$RRP_User" | _url_encode)"
  _rrp_body="$_rrp_body&s_pw=$(printf "%s" "$RRP_Pass" | _url_encode)"
  _rrp_body="$_rrp_body&command=$_rrp_cmd"
  if [ -n "$_rrp_extra" ]; then
    _rrp_body="$_rrp_body&$_rrp_extra"
  fi

  export _H1="Content-Type: application/x-www-form-urlencoded"
  response="$(_post "$_rrp_body" "$RRP_Api" "" "POST")"

  if [ "$?" != "0" ]; then
    _err "HTTP request to $RRP_Api failed."
    return 1
  fi

  _debug2 response "$response"

  if _contains "$response" "Command completed successfully"; then
    return 0
  fi
  return 1
}

# Walk up the label hierarchy to find the zone that actually exists in
# KeyDNS. _acme-challenge.reviews.example.com -> tries
# reviews.example.com, then example.com.
# Sets _zone and _sub_domain.
_get_root() {
  domain=$1
  i=2
  p=1

  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f $i-100)
    _debug h "$h"

    if [ -z "$h" ]; then
      return 1
    fi

    if _rrp_rest "StatusDNSZone" "dnszone=$(printf "%s" "$h" | _url_encode)"; then
      _zone="$h"
      _sub_domain=$(printf "%s" "$domain" | cut -d . -f 1-$p)
      if [ -z "$_sub_domain" ]; then
        _sub_domain="@"
      fi
      return 0
    fi

    p=$i
    i=$(_math "$i" + 1)
  done
  return 1
}
