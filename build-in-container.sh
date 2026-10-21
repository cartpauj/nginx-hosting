#!/usr/bin/env bash
# Runs inside ubuntu:18.04 (same C library and system libraries as the `hosting` droplet).
# Builds nginx $NGINX_VERSION into out/ and runs the acceptance checks.
set -euo pipefail
: "${NGINX_VERSION:?set NGINX_VERSION, e.g. 1.30.6}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq build-essential libssl-dev zlib1g-dev libpcre2-dev \
  curl ca-certificates gnupg binutils >/dev/null

WORK=$(mktemp -d)
cd "$WORK"
curl -fsSLO "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
curl -fsSLO "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz.asc"
for k in $(curl -fsSL https://nginx.org/en/pgp_keys.html | grep -oE '/keys/[A-Za-z0-9_.-]+\.key' | sort -u); do
  curl -fsSL "https://nginx.org$k" | gpg -q --import 2>/dev/null
done
gpg --verify "nginx-$NGINX_VERSION.tar.gz.asc" "nginx-$NGINX_VERSION.tar.gz"
tar xzf "nginx-$NGINX_VERSION.tar.gz"
cd "nginx-$NGINX_VERSION"

# Only what the droplet's config uses: ssl, http_v2, realip, rewrite, gzip, fastcgi, geo, map,
# access, index and logging. Everything else is left out, so fewer future advisories apply to
# us. Paths and hardening flags match the droplet's old Ubuntu build (minus -g debug info).
# OpenSSL, PCRE2 and zlib come from the system so the droplet's ESM updates keep patching them.
./configure \
  --with-cc-opt='-O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -D_FORTIFY_SOURCE=2' \
  --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -fPIC' \
  --prefix=/usr/share/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --http-log-path=/var/log/nginx/access.log \
  --error-log-path=/var/log/nginx/error.log \
  --lock-path=/var/lock/nginx.lock \
  --pid-path=/run/nginx.pid \
  --http-client-body-temp-path=/var/lib/nginx/body \
  --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_realip_module \
  --with-http_v2_module \
  --without-http_ssi_module \
  --without-http_charset_module \
  --without-http_proxy_module \
  --without-http_grpc_module \
  --without-http_uwsgi_module \
  --without-http_scgi_module \
  --without-http_memcached_module \
  --without-http_autoindex_module \
  --without-http_userid_module \
  --without-http_empty_gif_module \
  --without-http_browser_module \
  --without-http_split_clients_module \
  --without-http_mirror_module \
  --without-http_referer_module \
  --without-http_auth_basic_module \
  --without-http_limit_req_module \
  --without-http_limit_conn_module \
  --without-http_upstream_hash_module \
  --without-http_upstream_ip_hash_module \
  --without-http_upstream_least_conn_module \
  --without-http_upstream_random_module \
  --without-http_upstream_keepalive_module \
  --without-http_upstream_zone_module
make -j"$(nproc)" >/dev/null

OUT=/work/out
rm -rf "$OUT" && mkdir -p "$OUT"
install -s -m 755 objs/nginx "$OUT/nginx"   # -s strips symbols
cp LICENSE "$OUT/LICENSE"
cd "$OUT"

# Smoke test: a config using every feature the droplet depends on.
T=$(mktemp -d)
mkdir -p "$T/conf" "$T/logs" /var/lib/nginx /var/log/nginx
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$T/conf/key.pem" -out "$T/conf/cert.pem" 2>/dev/null
echo hi > "$T/index.html"; chmod 755 "$T"; chmod 644 "$T/index.html"
cat > "$T/conf/nginx.conf" <<CONF
user www-data;
worker_processes 1;
error_log $T/logs/error.log;
pid $T/nginx.pid;
events {}
http {
  access_log $T/logs/access.log;
  set_real_ip_from 127.0.0.1;
  real_ip_header CF-Connecting-IP;
  ssl_session_tickets off;
  gzip on;
  gzip_min_length 1;
  map \$http_x_test \$mapped { default no; yes mapped; }
  geo \$geo_test { default other; 127.0.0.1/32 local; }
  server {
    listen 8443 ssl;
    http2 on;
    ssl_certificate $T/conf/cert.pem;
    ssl_certificate_key $T/conf/key.pem;
    root $T;
    index index.html;
    location = /ip { return 200 "\$remote_addr\n"; }
    location = /map { return 200 "\$mapped \$geo_test\n"; }
    location = /denied { deny all; }
    location = /php { fastcgi_pass unix:/nonexistent.sock; }
  }
}
CONF

{
  echo "== nginx -V"; ./nginx -V 2>&1
  echo "== ldd"; ldd ./nginx
  echo "== newest glibc symbol needed (droplet has 2.27)"
  objdump -T ./nginx | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
  echo "== unwanted modules compiled in? (expect none)"
  ./nginx -V 2>&1 | grep -oE 'dav|slice|--with-mail|--with-stream|threads|stub_status|auth_request|gzip_static|addition|gunzip|sub_module' || echo none
  echo "== size"; du -h ./nginx | cut -f1
  echo "== nginx -t"; ./nginx -t -p "$T" -c "$T/conf/nginx.conf" 2>&1
  ./nginx -p "$T" -c "$T/conf/nginx.conf"; sleep 1
  echo "== HTTP version (expect 2)"; curl -sk --http2 -o /dev/null -w '%{http_version}\n' https://127.0.0.1:8443/
  echo "== realip (expect 203.0.113.7)"; curl -sk -H 'CF-Connecting-IP: 203.0.113.7' https://127.0.0.1:8443/ip
  echo "== index + gzip (expect gzip)"; curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -D - https://127.0.0.1:8443/ | grep -i '^content-encoding' || echo MISSING
  echo "== map + geo (expect mapped local)"; curl -sk -H 'X-Test: yes' https://127.0.0.1:8443/map
  echo "== access deny (expect 403)"; curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/denied
  echo "== fastcgi (expect 502, no PHP here)"; curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/php
  echo "== TLS 1.3 (expect TLSv1.3)"; echo | openssl s_client -connect 127.0.0.1:8443 -tls1_3 2>/dev/null | grep -oE 'TLSv1\.3' | head -1
  ./nginx -p "$T" -c "$T/conf/nginx.conf" -s quit
} > checks.txt 2>&1
sha256sum nginx > SHA256SUMS
cat checks.txt SHA256SUMS
