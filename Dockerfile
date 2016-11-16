FROM debian:jessie
MAINTAINER Steve Jabour <steve@jabour.me>

# persistent / runtime deps
ENV PHPIZE_DEPS \
    autoconf \
    file \
    g++ \
    gcc \
    libc-dev \
    make \
    pkg-config \
    re2c

RUN apt-get update && apt-get install -y \
    $PHPIZE_DEPS \
    ca-certificates \
    curl \
    libedit2 \
    libsqlite3-0 \
    libxml2 \
    xz-utils \
  --no-install-recommends && rm -r /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

ENV PHP_EXTRA_CONFIGURE_ARGS --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data

ENV GPG_KEYS 7DEC4E69FC9C83D7 C13C70B87267B52D D9C4D26D0E604491

ENV PHP_VERSION 5.3.29
ENV OPENSSL_VERSION 1.0.2d
ENV PHP_URL="https://secure.php.net/get/php-5.3.29.tar.xz/from/this/mirror"
ENV PHP_ASC_URL="https://secure.php.net/get/php-5.3.29.tar.xz.asc/from/this/mirror"
ENV PHP_SHA256="8438c2f14ab8f3d6cd2495aa37de7b559e33b610f9ab264f0c61b531bf0c262d"
ENV PHP_MD5="dcff9c881fe436708c141cfc56358075"
ENV OPENSSL_URL="https://www.openssl.org/source/openssl-1.0.2d.tar.gz"
ENV OPENSSL_ASC_URL="https://www.openssl.org/source/openssl-1.0.2d.tar.gz.asc"
ENV OPENSSL_SHA256="671c36487785628a703374c652ad2cebea45fa920ae5681515df25d9f2c9a8c8"
ENV OPENSSL_MD5="38dd619b2e77cbac69b99f52a053d25a"

RUN set -xe; \
  \
  fetchDeps=' \
    wget \
  '; \
  apt-get update; \
  apt-get install -y --no-install-recommends $fetchDeps; \
  rm -rf /var/lib/apt/lists/*; \
  \
  mkdir -p /usr/src; \
  cd /usr/src; \
  \
  wget -O openssl.tar.gz "$OPENSSL_URL"; \
  wget -O php.tar.xz "$PHP_URL"; \
  \
  if [ -n "$OPENSSL_SHA256" ]; then \
    echo "$OPENSSL_SHA256 *openssl.tar.gz" | sha256sum -c -; \
  fi; \
  if [ -n "$OPENSSL_MD5" ]; then \
    echo "$OPENSSL_MD5 *openssl.tar.gz" | md5sum -c -; \
  fi; \
  if [ -n "$PHP_SHA256" ]; then \
    echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
  fi; \
  if [ -n "$PHP_MD5" ]; then \
    echo "$PHP_MD5 *php.tar.xz" | md5sum -c -; \
  fi; \
  \
  export GNUPGHOME="$(mktemp -d)"; \
  \
  for key in $GPG_KEYS; do \
    gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
  done; \
  \
  if [ -n "$OPENSSL_ASC_URL" ]; then \
    wget -O openssl.tar.gz.asc "$OPENSSL_ASC_URL"; \
    gpg --batch --verify openssl.tar.gz.asc openssl.tar.gz; \
  fi; \
  \
  if [ -n "$PHP_ASC_URL" ]; then \
    wget -O php.tar.xz.asc "$PHP_ASC_URL"; \
    gpg --batch --verify php.tar.xz.asc php.tar.xz; \
  fi; \
  \
  rm -r "$GNUPGHOME"; \
  \
  apt-get purge -y --auto-remove $fetchDeps

COPY docker-openssl-source /usr/local/bin/
COPY docker-php-source /usr/local/bin/

RUN set -xe \
  && docker-openssl-source extract \
  && cd /usr/src/openssl \
  && ./config \
  && make \
  && make install \
  && docker-openssl-source delete

RUN set -xe \
  && buildDeps=" \
    $PHP_EXTRA_BUILD_DEPS \
    libcurl4-openssl-dev \
    libedit-dev \
    libsqlite3-dev \
    libssl-dev \
    libxml2-dev \
  " \
  && apt-get update && apt-get install -y $buildDeps --no-install-recommends && rm -rf /var/lib/apt/lists/* \
  \
  && docker-php-source extract \
  && cd /usr/src/php \
  && ./configure \
    --with-config-file-path="$PHP_INI_DIR" \
    --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
    \
    --disable-cgi \
    \
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
    --enable-ftp \
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
    --enable-mbstring \
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
    --enable-mysqlnd \
    \
    --with-curl \
    --with-libedit \
    --with-openssl=/usr/local/ssl \
    --with-zlib \
    \
    $PHP_EXTRA_CONFIGURE_ARGS \
  && make -j "$(nproc)" \
  && make install \
  && { find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; } \
  && make clean \
  && docker-php-source delete \
  \
  && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $buildDeps

COPY docker-php-ext-* /usr/local/bin/

WORKDIR /var/www/html

RUN set -ex \
  && cd /usr/local/etc \
  && if [ -d php-fpm.d ]; then \
    # for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
    sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
    cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
  else \
    # PHP 5.x don't use "include=" by default, so we'll create our own simple config that mimics PHP 7+ for consistency
    mkdir php-fpm.d; \
    cp php-fpm.conf.default php-fpm.d/www.conf; \
    { \
      echo '[global]'; \
      echo 'include=etc/php-fpm.d/*.conf'; \
    } | tee php-fpm.conf; \
  fi \
  && { \
    echo '[global]'; \
    echo 'error_log = /proc/self/fd/2'; \
    echo; \
    echo '[www]'; \
    echo '; if we send this to /proc/self/fd/1, it never appears'; \
    echo 'access.log = /proc/self/fd/2'; \
    echo; \
    echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
    echo 'catch_workers_output = yes'; \
  } | tee php-fpm.d/docker.conf \
  && { \
    echo '[global]'; \
    echo 'daemonize = no'; \
    echo; \
    echo '[www]'; \
    echo 'listen = 9000'; \
    echo; \
    echo '; The URI to view the FPM status page.'; \
    echo 'pm.status_path = /status'; \
    echo; \
    echo ';The ping URI to call the monitoring page of FPM.'; \
    echo 'ping.path = /ping'; \
  } | tee php-fpm.d/zz-docker.conf

EXPOSE 9000
CMD ["php-fpm"]
