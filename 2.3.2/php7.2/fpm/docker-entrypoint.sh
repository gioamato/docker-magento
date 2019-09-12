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

if [[ "$1" == apache2* ]] || [ "$1" == php-fpm ]; then
	if [ "$(id -u)" = '0' ]; then
		case "$1" in
			apache2*)
				user="${APACHE_RUN_USER:-www-data}"
				group="${APACHE_RUN_GROUP:-www-data}"

				# strip off any '#' symbol ('#1000' is valid syntax for Apache)
				pound='#'
				user="${user#$pound}"
				group="${group#$pound}"
				;;
			*) # php-fpm
				user='www-data'
				group='www-data'
				;;
		esac
	else
		user="$(id -u)"
		group="$(id -g)"
	fi

	if [ ! -e index.php ] && [ ! -e bin/magento ]; then
		# if the directory exists and Magento doesn't appear to be installed AND the permissions of it are root:root
		# let's chown it (likely a Docker-created directory)
		if [ "$(id -u)" = '0' ] && [ "$(stat -c '%u:%g' .)" = '0:0' ]; then
			chown "$user:$group" .
		fi

		# allow Magento authentication keys to be specified via environment variables
		authEnvs=(
				MAGENTO_PUBLIC_KEY
				MAGENTO_PRIVATE_KEY
			)

		haveAuth=
		for e in "${authEnvs[@]}"; do
			file_env "$e"
			if [ -z "$haveAuth" ] && [ -n "${!e}" ]; then
				haveAuth=1
			fi
		done

		# Install Magento CE using Composer if we have environment-supplied key values
		# see https://devdocs.magento.com/guides/v2.3/install-gde/composer.html
		if [ "$haveAuth" ]; then
			echo >&2 "Installing Magento using Composer..."
			composer global config --quiet http-basic.repo.magento.com "$MAGENTO_PUBLIC_KEY" "$MAGENTO_PRIVATE_KEY"
			composer create-project --quiet --repository=https://repo.magento.com/ magento/project-community-edition /usr/src/magento
			echo >&2 "Complete! Magento has been successfully installed"
		else
			echo >&2 "Cannot install Magento using Composer. Authentication keys are required"
			echo >&2 "Aborting..."
			exit 1
		fi

		echo >&2 "Magento not found in $PWD - copying now..."

		if [ -n "$(ls -A)" ]; then
			echo >&2 "WARNING: $PWD is not empty! (copying anyhow)"
		fi

		sourceTarArgs=(
			--create
			--file -
			--directory /usr/src/magento
			--owner "$user" --group "$group"
		)

		targetTarArgs=(
			--extract
			--file -
		)

		if [ "$user" != '0' ]; then
			# avoid "tar: .: Cannot utime: Operation not permitted" and "tar: .: Cannot change mode to rwxr-xr-x: Operation not permitted"
			targetTarArgs+=( --no-overwrite-dir )
		fi
		
		tar "${sourceTarArgs[@]}" . | tar "${targetTarArgs[@]}"
		echo >&2 "Complete! Magento has been successfully copied to $PWD"

		# set recommended file permissions
		# see https://devdocs.magento.com/guides/v2.3/install-gde/composer.html#set-file-permissions
		echo >&2 "Fixing permissions..."
		find var generated vendor pub/static pub/media app/etc -type f -exec chmod g+w {} + \
			&& find var generated vendor pub/static pub/media app/etc -type d -exec chmod g+ws {} + \
			&& chmod u+x bin/magento

		# adding Magento crontab and starting cron
		# further reading https://devdocs.magento.com/guides/v2.3/config-guide/cli/config-cli-subcommands-cron.html
		echo >&2 "Creating Magento crontab..."
		printf \
'#~ MAGENTO START
* * * * * /usr/local/bin/php /var/www/html/bin/magento cron:run 2>&1 | grep -v "Ran jobs by schedule" >> /var/www/html/var/log/magento.cron.log
* * * * * /usr/local/bin/php /var/www/html/update/cron.php >> /var/www/html/var/log/update.cron.log
* * * * * /usr/local/bin/php /var/www/html/bin/magento setup:cron:run >> /var/www/html/var/log/setup.cron.log
#~ MAGENTO END' \
			>> /etc/cron.d/magento2-cron
		chmod 0644 /etc/cron.d/magento2-cron
		crontab -u www-data /etc/cron.d/magento2-cron
	fi

	# allow any of these required variables to be specified via
	# environment variables with a "MAGENTO_" prefix (ie, "MAGENTO_BASE_URL")
	requiredEnvs=(
		BASE_URL
		ADMIN_FIRSTNAME
		ADMIN_LASTNAME
		ADMIN_EMAIL
		ADMIN_USER
		ADMIN_PASSWORD
		DB_HOST
		DB_NAME
		DB_USER
		DB_PASSWORD
	)

	envs=(
		"${requiredEnvs[@]/#/MAGENTO_}"
		MAGENTO_ENCRYPTION_KEY
		MAGENTO_TABLE_PREFIX
		MAGENTO_LANGUAGE
		MAGENTO_CURRENCY
		MAGENTO_TIMEZONE
		MAGENTO_REWRITES
		MAGENTO_SECURE
		MAGENTO_SECURE_ADMIN
		MAGENTO_SECURE_URL
		MAGENTO_ADMIN_URI
	)

	haveConfig=
	for e in "${envs[@]}"; do
		file_env "$e"
		if [ -z "$haveConfig" ] && [ -n "${!e}" ]; then
			haveConfig=1
		fi
	done

	# linking backwards-compatibility
	if [ -n "${!MYSQL_ENV_MYSQL_*}" ]; then
		haveConfig=1
		# host defaults to "mysql" below if unspecified
		: "${MAGENTO_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}"
		if [ "$MAGENTO_DB_USER" = 'root' ]; then
			: "${MAGENTO_DB_PASSWORD:=${MYSQL_ENV_MYSQL_ROOT_PASSWORD:-}}"
		else
			: "${MAGENTO_DB_PASSWORD:=${MYSQL_ENV_MYSQL_PASSWORD:-}}"
		fi
		: "${MAGENTO_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-}}"
	fi

	# only setup magento if we have environment-supplied configuration values
	if [ "$haveConfig" ]; then
		: "${MAGENTO_DB_HOST:=mysql}"
		: "${MAGENTO_DB_USER:=root}"
		: "${MAGENTO_DB_PASSWORD:=}"
		: "${MAGENTO_DB_NAME:=magento}"

		# database might not exist, so let's try creating it (just to be safe)
		if ! TERM=dumb php -- <<'EOPHP'
<?php
$stderr = fopen('php://stderr', 'w');
list($host, $socket) = explode(':', getenv('MAGENTO_DB_HOST'), 2);
$port = 0;
if (is_numeric($socket)) {
	$port = (int) $socket;
	$socket = null;
}
$user = getenv('MAGENTO_DB_USER');
$pass = getenv('MAGENTO_DB_PASSWORD');
$dbName = getenv('MAGENTO_DB_NAME');
$maxTries = 10;
do {
	$mysql = new mysqli($host, $user, $pass, '', $port, $socket);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);
if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($dbName) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}
$mysql->close();
EOPHP
		then
			echo >&2
			echo >&2 "WARNING: unable to establish a database connection to '$MAGENTO_DB_HOST'"
			echo >&2 '  continuing anyways (which might have unexpected results)'
			echo >&2
		fi

		# Setup Magento via CLI if the required variables are all set
		haveRequired=1
		for required in "${requiredEnvs[@]}"; do
			requiredVar="MAGENTO_$required"
			if [ -z "${!requiredVar}" ]; then
				echo >&2 "$requiredVar is required! Cannot setup Magento via CLI"
				haveRequired=0
			fi
		done

		# Check if Magento hasn't been setup yet
		if [ "$haveRequired" ] && [ ! -e app/etc/env.php ]; then
			# build up arguments in an array
			# see https://stackoverflow.com/a/28678964
			args=(
				--base-url="$MAGENTO_BASE_URL"
				--db-host="$MAGENTO_DB_HOST"
				--db-name="$MAGENTO_DB_NAME"
				--db-user="$MAGENTO_DB_USER"
				--db-password="$MAGENTO_DB_PASSWORD"
				--admin-firstname="$MAGENTO_ADMIN_FIRSTNAME"
				--admin-lastname="$MAGENTO_ADMIN_LASTNAME"
				--admin-email="$MAGENTO_ADMIN_EMAIL"
				--admin-user="$MAGENTO_ADMIN_USER"
				--admin-password="$MAGENTO_ADMIN_PASSWORD"
			)

			if [ "$MAGENTO_ENCRYPTION_KEY" ]; then
				args+=(
					--key="$MAGENTO_ENCRYPTION_KEY"
				)
			fi

			if [ "$MAGENTO_TABLE_PREFIX" ]; then
				args+=(
					--db-prefix="$MAGENTO_TABLE_PREFIX"
				)
			fi

			if [ "$MAGENTO_LANGUAGE" ]; then
				args+=(
					--language="$MAGENTO_LANGUAGE"
				)
			fi

			if [ "$MAGENTO_CURRENCY" ]; then
				args+=(
					--currency="$MAGENTO_CURRENCY"
				)
			fi

			if [ "$MAGENTO_TIMEZONE" ]; then
				args+=(
					--timezone="$MAGENTO_TIMEZONE"
				)
			fi

			if [ "$MAGENTO_REWRITES" ]; then
				args+=(
					--use-rewrites="$MAGENTO_REWRITES"
				)
			fi

			if [ "$MAGENTO_SECURE" ]; then
				args+=(
					--use-secure="$MAGENTO_SECURE"
				)
			fi

			if [ "$MAGENTO_SECURE_ADMIN" ]; then
				args+=(
					--use-secure-admin="$MAGENTO_SECURE_ADMIN"
				)
			fi

			if [ "$MAGENTO_SECURE_URL" ]; then
				args+=(
					--base-url-secure="$MAGENTO_SECURE_URL"
				)
			fi

			if [ "$MAGENTO_ADMIN_URI" ]; then
				args+=(
					--backend-frontname="$MAGENTO_ADMIN_URI"
				)
			fi

			# setup Magento with passed arguments
			bin/magento setup:install --quiet --no-interaction ${args[@]} && chown -R www-data:www-data /var/www/html
		else
			echo >&2 "Please, use Magento Web Setup Wizard"
		fi
	fi

	# now that we're definitely done with the setup, let's clear out the relevant envrionment variables (so that stray "phpinfo()" calls don't leak secrets from our code)
	for e in "${envs[@]}"; do
		unset "$e"
	done

	# Start cron service
	service cron start
fi

exec "$@"