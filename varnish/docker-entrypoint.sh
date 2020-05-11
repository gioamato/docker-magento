#!/bin/bash
set -euo pipefail

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# allow configuration to be specified via environment variables
envs=(
		BACKEND_HOST
		PURGE_HOST
	)

haveConfig=
for e in "${envs[@]}"; do
	file_env "$e"
	if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
		haveConfig=1
	fi
done

# set backend host if we have environment-supplied configuration value
# otherwise use 'localhost'
: "${BACKEND_HOST:=localhost}"
echo >&2 "Setting '$BACKEND_HOST' as backend host"
sed -i -e "s/BACKEND_HOST/$BACKEND_HOST/g" /etc/varnish/default.vcl

# set purge host if we have environment-supplied configuration value
# otherwise use 'localhost'
# TODO: allow to specify access list (multiple hosts)
: "${PURGE_HOST:=localhost}"
echo >&2 "Setting '$PURGE_HOST' as purge host"
sed -i -e "s/PURGE_HOST/$PURGE_HOST/g" /etc/varnish/default.vcl

# wait backend host availability then start Varnish service
wait-for-it $BACKEND_HOST:80 --timeout=300 --strict
echo >&2 "Starting Varnish service..."

# this will check if the first argument is a flag
# but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- varnishd -F -f /etc/varnish/default.vcl -a http=:80,HTTP -a proxy=:8443,PROXY -s malloc,$VARNISH_SIZE "$@"
fi

exec "$@"
