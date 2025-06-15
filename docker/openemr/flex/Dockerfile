
ARG ALPINE_VERSION=3.22
ARG PHP_VERSION=8.4
ENV PHP_VERSION=${PHP_VERSION}

FROM alpine:${ALPINE_VERSION}

# Set PHP package version based on PHP_VERSION (8.4 -> 84, 8.3 -> 83, etc.)
RUN export PHP_PKG_VER=$(echo ${PHP_VERSION} | sed 's/\.//')
ENV PHP_PKG_VER=${PHP_PKG_VER}

#Prepare to install dependencies
RUN apk --no-cache upgrade

# Install stuff for developers since this predominantly a developer/tester docker
RUN apk add --no-cache \
    unzip vim nano bash bash-doc bash-completion tree

# Install non-php packages
RUN apk add --no-cache \
    apache2 apache2-ssl apache2-utils apache2-proxy git perl \
    mariadb-client mariadb-connector-c tar curl imagemagick nodejs npm \
    certbot openssl git openssl-dev dcron \
    rsync shadow jq ncurses

# Install PHP and its extensions
RUN apk add --no-cache \
    php${PHP_PKG_VER} \
    php${PHP_PKG_VER}-tokenizer \
    php${PHP_PKG_VER}-ctype \
    php${PHP_PKG_VER}-session \
    php${PHP_PKG_VER}-apache2 \
    php${PHP_PKG_VER}-json \
    php${PHP_PKG_VER}-pdo \
    php${PHP_PKG_VER}-pdo_mysql \
    php${PHP_PKG_VER}-curl \
    php${PHP_PKG_VER}-ldap \
    php${PHP_PKG_VER}-openssl \
    php${PHP_PKG_VER}-iconv \
    php${PHP_PKG_VER}-xml \
    php${PHP_PKG_VER}-xsl \
    php${PHP_PKG_VER}-gd \
    php${PHP_PKG_VER}-zip \
    php${PHP_PKG_VER}-soap \
    php${PHP_PKG_VER}-mbstring \
    php${PHP_PKG_VER}-zlib \
    php${PHP_PKG_VER}-mysqli \
    php${PHP_PKG_VER}-sockets \
    php${PHP_PKG_VER}-xmlreader \
    php${PHP_PKG_VER}-redis \
    php${PHP_PKG_VER}-simplexml \
    php${PHP_PKG_VER}-xmlwriter \
    php${PHP_PKG_VER}-phar \
    php${PHP_PKG_VER}-fileinfo \
    php${PHP_PKG_VER}-sodium \
    php${PHP_PKG_VER}-calendar \
    php${PHP_PKG_VER}-intl \
    php${PHP_PKG_VER}-opcache \
    php${PHP_PKG_VER}-pecl-apcu \
    php${PHP_PKG_VER}-fpm

# fix issue in apache
RUN sed -i 's/^Listen 80$/Listen 0.0.0.0:80/' /etc/apache2/httpd.conf

# Needed to ensure permissions work across shared volumes with openemr, nginx, and php-fpm dockers
RUN usermod -u 1000 apache

#BELOW LINE NEEDED TO SUPPORT PHP8 ON ALPINE 3.13+; SHOULD BE ABLE TO REMOVE THIS IN FUTURE ALPINE VERSIONS
RUN cp /usr/bin/php${PHP_PKG_VER} /usr/bin/php
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

# TODO: Note that flex series 3.14+ needs to keep build-base package in (ie. not apk del it after done) for now
#  since npm package libxmljs needs to be built during openemr build; this is part of the ccda npm build and
#  can place build-base in below apk del line when this issue is fixed)
#  btw, when this is fixed and we apk del build-base (actually, will not even need to install it),
#     this will decrease size of docker by 190MB :)
RUN apk add --no-cache build-base \
    && mkdir -p /var/www/localhost/htdocs/openemr/sites \
    && chown -R apache /var/www/localhost/htdocs/openemr \
    && mkdir -p /etc/ssl/certs /etc/ssl/private \
    # && apk del --no-cache build-base \
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *ErrorLog/#ErrorLog/' /etc/apache2/httpd.conf \
    && sed -i 's/^ *CustomLog/#CustomLog/' /etc/apache2/conf.d/ssl.conf \
    && sed -i 's/^ *TransferLog/#TransferLog/' /etc/apache2/conf.d/ssl.conf
WORKDIR /var/www/localhost/htdocs
VOLUME [ "/etc/letsencrypt/", "/etc/ssl" ]
#configure apache & php properly
ENV APACHE_LOG_DIR=/var/log/apache2
COPY configs/php${PHP_VERSION}/php.ini /etc/php${PHP_PKG_VER}/php.ini
COPY openemr.conf /etc/apache2/conf.d/
#add runner and auto_configure and prevent auto_configure from being run w/o being enabled
COPY openemr.sh ssl.sh xdebug.sh auto_configure.php /var/www/localhost/htdocs/
COPY utilities/unlock_admin.php utilities/unlock_admin.sh /root/
RUN chmod 500 openemr.sh ssl.sh xdebug.sh /root/unlock_admin.sh \
    && chmod 000 auto_configure.php /root/unlock_admin.php
#fix issue with apache2 dying prematurely
RUN mkdir -p /run/apache2
#Copy dev tools alias to root and create snapshots and certs dir
COPY utilities/devtools /root/
COPY utilities/devtoolsLibrary.source /root/
RUN mkdir /snapshots
RUN mkdir /certs
RUN mkdir -p /couchdb/original
#Copy demo data to root
COPY utilities/demo_5_0_0_5.sql /root/
RUN chmod 500 /root/devtools
#Ensure swarm/orchestration pieces are available if needed
RUN mkdir /swarm-pieces \
    && rsync --owner --group --perms --delete --recursive --links /etc/ssl /swarm-pieces/
#go
CMD [ "./openemr.sh" ]

EXPOSE 80 443
