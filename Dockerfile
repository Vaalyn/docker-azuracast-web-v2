FROM golang:alpine AS jobber

RUN apk add --no-cache rsync git alpine-sdk

WORKDIR /go/src/app

ARG JOBBER_COMMIT=2674486141de812de8b2d053f1edc54a0593dbfd

RUN mkdir -p src/github.com/dshearer \
    && cd src/github.com/dshearer \
    && git clone https://github.com/dshearer/jobber.git \
    && cd jobber \
    && git reset --hard $JOBBER_COMMIT \
    && make check \
    && make install

FROM alpine:3.9

RUN apk add --no-cache ca-certificates s6 curl wget tar sudo zip unzip git rsync tzdata bash \
    nginx openssl certbot \
    php7 php7-fpm php7-cli \
    php7-phar php7-tokenizer php7-iconv php7-dom php7-curl \
    php7-mbstring php7-openssl php7-fileinfo php7-gd php7-intl \
    php7-simplexml php7-xml php7-xmlreader php7-xmlwriter php7-json php7-redis php7-pdo \
    php7-pdo_mysql php7-mysqlnd

# Create azuracast user.
RUN adduser -h /var/azuracast -D -g "" azuracast \
    && addgroup azuracast www-data \
    && mkdir -p /var/azuracast/www /var/azuracast/www_tmp /var/azuracast/geoip \
    && chown -R azuracast:azuracast /var/azuracast \
    && chmod -R 777 /var/azuracast/www_tmp \
    && echo 'azuracast ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Install nginx and configuration
COPY ./nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./nginx/azuracast.conf /etc/nginx/conf.d/azuracast.conf

RUN rm -f /etc/nginx/conf.d/default.conf

# Generate the dhparam.pem file (takes a long time)
RUN openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 4096

# Set certbot permissions
RUN mkdir -p /var/www/letsencrypt /var/lib/letsencrypt /etc/letsencrypt /var/log/letsencrypt \
    && chown -R azuracast:azuracast /var/www/letsencrypt /var/lib/letsencrypt /etc/letsencrypt /var/log/letsencrypt

# Install PHP 7.2
RUN mkdir -p /run/php
RUN touch /run/php/php7.2-fpm.pid

COPY ./php/php.ini.tmpl /etc/php7/05-azuracast.ini.tmpl
COPY ./php/phpfpmpool.conf /etc/php7/php-fpm.d/www.conf

# Install MaxMind GeoIP Lite
RUN wget http://geolite.maxmind.com/download/geoip/database/GeoLite2-City.tar.gz \
    && tar -C /var/azuracast/geoip -xzvf GeoLite2-City.tar.gz --strip-components 1 \
    && rm GeoLite2-City.tar.gz \
    && chown -R azuracast:azuracast /var/azuracast/geoip

# Install Dockerize
ENV DOCKERIZE_VERSION="v0.6.1"
RUN wget https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && tar -C /usr/local/bin -xzvf dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz \
    && rm dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz

# Install Jobber
COPY --from=jobber /usr/local/libexec/jobbermaster /usr/local/bin/jobbermaster
COPY --from=jobber /usr/local/libexec/jobberrunner /usr/local/bin/jobberrunner
COPY --from=jobber /usr/local/bin/jobber /usr/local/bin/jobber

COPY ./jobber.yml /var/azuracast/.jobber

RUN chown azuracast:azuracast /var/azuracast/.jobber \
    && chmod 644 /var/azuracast/.jobber \
    && mkdir -p /var/jobber/1000 \
    && chown -R azuracast:azuracast /var/jobber/1000 

# Install composer
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/bin --filename=composer

# AzuraCast installer and update commands
COPY scripts/ /usr/local/bin
RUN chmod -R a+x /usr/local/bin

# Set up running services
COPY ./services/ /etc/system/

RUN chmod +x /etc/system/*/run

# Copy crontab
COPY ./cron/ /etc/cron.d/

#
# START Operations as `azuracast` user
#
USER azuracast

# Add global Composer deps
RUN composer create-project azuracast/azuracast /var/azuracast/new ^0.9.3 --no-dev --keep-vcs \
    && mv /var/azuracast/new/vendor /var/azuracast/www \
    && rm -rf /var/azuracast/new

# Alert AzuraCast that it's running in Docker mode
RUN touch /var/azuracast/.docker

# SSL self-signed cert generation
RUN openssl req -new -nodes -x509 -subj "/C=US/ST=Texas/L=Austin/O=IT/CN=localhost" \
    -days 365 -extensions v3_ca \
    -keyout /etc/letsencrypt/selfsigned.key \
	-out /etc/letsencrypt/selfsigned.crt

RUN ln -s /etc/letsencrypt/selfsigned.key /etc/letsencrypt/ssl.key \
    && ln -s /etc/letsencrypt/selfsigned.crt /etc/letsencrypt/ssl.crt

VOLUME /etc/letsencrypt

# Clone repo and set up AzuraCast repo
WORKDIR /var/azuracast/www
VOLUME /var/azuracast/www

#
# END Operations as `azuracast` user
#
USER root

# Sensible default environment variables.
ENV APPLICATION_ENV="production" \
    MYSQL_HOST="mariadb" \
    MYSQL_PORT=3306 \
    MYSQL_USER="azuracast" \
    MYSQL_PASSWORD="azur4c457" \
    MYSQL_DATABASE="azuracast"

# Entrypoint and default command
ENTRYPOINT ["dockerize",\
    "-wait","tcp://mariadb:3306",\
    "-wait","tcp://influxdb:8086",\
    "-template","/etc/php7/05-azuracast.ini.tmpl:/etc/php7/conf.d/05-azuracast.ini",\
    "-timeout","20s"]

CMD ["s6-svscan", "/etc/system"]