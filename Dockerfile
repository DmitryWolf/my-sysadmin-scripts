FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends procps python3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 app \
    && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin app \
    && mkdir -p /var/www \
    && chown 1000:1000 /var/www

COPY script.sh container-entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/script.sh /usr/local/bin/container-entrypoint.sh

WORKDIR /var/www
USER 1000:1000
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
