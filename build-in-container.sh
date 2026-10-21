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

# The droplet's own build options (its `nginx -V`), minus: the old build machine's
# -fdebug-prefix-map/-Wdate-time flags, dav and slice (unused, 2026 CVEs), --with-debug
# (debug logging code production doesn't need), and --with-compat/--modules-path (only for
# loadable modules; none are used). OpenSSL, PCRE2 and zlib come from the
# system so the droplet's ESM updates keep patching them.
./configure \
  --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -D_FORTIFY_SOURCE=2' \
  --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -fPIC' \
  --prefix=/usr/share/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --http-log-path=/var/log/nginx/access.log \
  --error-log-path=/var/log/nginx/error.log \
  --lock-path=/var/lock/nginx.lock \
  --pid-path=/run/nginx.pid \
  --http-client-body-temp-path=/var/lib/nginx/body \
  --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
  --http-proxy-temp-path=/var/lib/nginx/proxy \
  --http-scgi-temp-path=/var/lib/nginx/scgi \
  --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_realip_module \
  --with-http_auth_request_module \
  --with-http_v2_module \
  --with-threads \
  --with-http_addition_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_sub_module
make -j"$(nproc)" >/dev/null

OUT=/work/out
rm -rf "$OUT" && mkdir -p "$OUT"
install -m 755 objs/nginx "$OUT/nginx"
cp LICENSE "$OUT/LICENSE"
cd "$OUT"

# Smoke test: a config using every feature the droplet depends on.
T=$(mktemp -d)
mkdir -p "$T/conf" "$T/logs" /var/lib/nginx /var/log/nginx
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$T/conf/key.pem" -out "$T/conf/cert.pem" 2>/dev/null
echo hi > "$T/index.html"; gzip -k "$T/index.html"; chmod 755 "$T"; chmod 644 "$T"/index.html*
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
  aio threads;
  server {
    listen 8443 ssl;
    http2 on;
    ssl_certificate $T/conf/cert.pem;
    ssl_certificate_key $T/conf/key.pem;
    root $T;
    gzip_static on;
    location = /ip { return 200 "\$remote_addr\n"; }
    location = /private { auth_request /auth; return 200 "auth ok\n"; }
    location = /auth { internal; return 204; }
  }
}
CONF

{
  echo "== nginx -V"; ./nginx -V 2>&1
  echo "== ldd"; ldd ./nginx
  echo "== newest glibc symbol needed (droplet has 2.27)"
  objdump -T ./nginx | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1
  echo "== dav/slice/mail/stream compiled in? (expect none)"
  ./nginx -V 2>&1 | grep -oE 'dav|slice|--with-mail|--with-stream' || echo none
  echo "== nginx -t"; ./nginx -t -p "$T" -c "$T/conf/nginx.conf" 2>&1
  ./nginx -p "$T" -c "$T/conf/nginx.conf"; sleep 1
  echo "== HTTP version (expect 2)"; curl -sk --http2 -o /dev/null -w '%{http_version}\n' https://127.0.0.1:8443/
  echo "== realip (expect 203.0.113.7)"; curl -sk -H 'CF-Connecting-IP: 203.0.113.7' https://127.0.0.1:8443/ip
  echo "== auth_request (expect auth ok)"; curl -sk https://127.0.0.1:8443/private
  echo "== gzip_static (expect gzip)"; curl -sk -H 'Accept-Encoding: gzip' -o /dev/null -D - https://127.0.0.1:8443/index.html | grep -i '^content-encoding' || echo MISSING
  echo "== TLS 1.3 (expect TLSv1.3)"; echo | openssl s_client -connect 127.0.0.1:8443 -tls1_3 2>/dev/null | grep -oE 'TLSv1\.3' | head -1
  ./nginx -p "$T" -c "$T/conf/nginx.conf" -s quit
} > checks.txt 2>&1
sha256sum nginx > SHA256SUMS
cat checks.txt SHA256SUMS
