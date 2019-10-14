FROM php:7.3-fpm

# Install Libraries and PHP Extensions
RUN set -ex; \
        \
        apt-get update; \
	    apt-get install -y --no-install-recommends \
            cron \
            lsof \
            libzip-dev \
            zip \
            unzip \
            libjpeg-dev \
            libmagickwand-dev \
            libpng-dev \
            libmcrypt-dev \
            libmcrypt4 \
            libcurl3-dev \
            libfreetype6-dev \
            libfreetype6 \
            libjpeg62-turbo-dev \
            libjpeg62-turbo \
            libicu-dev \
            libxslt1-dev \
        ; \
        \
        docker-php-ext-configure gd \
            --with-freetype-dir=/usr \
            --with-jpeg-dir=/usr \
            --with-png-dir=/usr \
        ; \
        docker-php-ext-configure zip \
            --with-libzip \
        ; \
        docker-php-ext-install -j "$(nproc)" \
            bcmath \
            gd \
            intl \
            mysqli \
            opcache \
            pdo_mysql \
            soap \
            xsl \
            zip \
        ; \
        pecl install imagick-3.4.4; \
	    docker-php-ext-enable imagick; \
        \
        # Install Composer
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; \
        \
        # Clean (official Debian and Ubuntu images automatically run apt-get clean, so explicit invocation is not required)
        rm -rf /var/lib/apt/lists/*

# Set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=2'; \
		echo 'opcache.fast_shutdown=1'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Configure Error Logging
RUN { \
		echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
		echo 'display_errors = Off'; \
		echo 'display_startup_errors = Off'; \
		echo 'log_errors = On'; \
		echo 'error_log = /dev/stderr'; \
		echo 'log_errors_max_len = 1024'; \
		echo 'ignore_repeated_errors = On'; \
		echo 'ignore_repeated_source = Off'; \
		echo 'html_errors = Off'; \
	} > /usr/local/etc/php/conf.d/error-logging.ini

# Create a mount point at '/var/www/html'
VOLUME /var/www/html

# Add entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]