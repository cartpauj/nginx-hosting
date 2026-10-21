# nginx-hosting

nginx for an Ubuntu 18.04 server whose packaged nginx no longer gets updates.
It's built on GitHub Actions inside an `ubuntu:18.04` container, so it uses the server's own C library and
its system OpenSSL 1.1.1, PCRE2 and zlib. Those keep getting security fixes from the server's
own updates (Ubuntu ESM); nothing is bundled.

- `build-in-container.sh`: downloads nginx, checks its signature, builds it, runs the checks.
- `.github/workflows/build.yml`: runs that script in Docker. GitHub's own steps can't run inside
  an 18.04 container, so only the compile does.
- `build.sh`: one command to build, download, check and (optionally) publish.

## Build options

Only what the server's config uses: SSL, HTTP/2, realip, rewrite, gzip, fastcgi, geo, map,
access, index and logging. Everything else is left out (proxy, gRPC, SSI, charset, basic auth,
rate limiting, upstream balancers, dav, slice, mail, stream, all add-on modules...), so fewer
future advisories apply. Needing one of those later means a rebuild: add it in
`build-in-container.sh`.

Paths (config, logs, pid, `/var/lib/nginx` temp dirs) and hardening flags match the server's old
Ubuntu nginx. The binary is stripped (no debug info).

## Building a new version

```
./build.sh            # newest stable from nginx.org, saved in builds/<version>/
                      # (rebuilding the same version becomes <version>-2, -3...)
./build.sh --release  # same, then publish a public GitHub Release
```

Takes about 2 minutes. Review `builds/<version>/checks.txt` before releasing.

## Installing (on the server)

Needs `libpcre2-8-0` (`apt install libpcre2-8-0`). Put the binary at `/opt/nginx/sbin/nginx`,
remove `include /etc/nginx/modules-enabled/*.conf;` from nginx.conf, test with
`sudo /opt/nginx/sbin/nginx -t`, then point the systemd service at it. Certbot renews using
`/usr/sbin/nginx`, so point that at the new binary too and prove it with `sudo certbot renew --dry-run`.

## Builds

| Version | Date | Run | Release |
|---|---|---|---|
| 1.30.6 | 2026-10-21 | [39677201752](https://github.com/cartpauj/nginx-hosting/actions/runs/39677201752) | [nginx-1.30.6](https://github.com/cartpauj/nginx-hosting/releases/tag/nginx-1.30.6) |
