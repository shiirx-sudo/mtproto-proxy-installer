# mtproto-proxy-installer

## Short automatic install

Default production install: MTG on `443/tcp`, AmneziaWG on `443/udp`, UFW enabled, auto-updates enabled, old MTProto/MTG removed, random `MASK_DOMAIN` from the built-in list, auto-reboot enabled.

```bash
curl -fsSL https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main/quick-install.sh | sudo bash
```

With a fixed mask domain and AWG subnet:

```bash
curl -fsSL https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main/quick-install.sh \
  | sudo bash -s -- --mask-domain ya.ru --awg-subnet 10.66.66.0/24
```

Without AmneziaWG:

```bash
curl -fsSL https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main/quick-install.sh \
  | sudo bash -s -- --no-awg
```

Without automatic reboot:

```bash
curl -fsSL https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main/quick-install.sh \
  | sudo bash -s -- --no-reboot
```

Full manual installer remains available through `install.sh`.

Production installer for Telegram MTProto proxy through **MTG v2 FakeTLS** with optional **AmneziaWG** administrative VPN access.

## What it does

- Checks for existing MTProto/MTG services, Docker containers and configs.
- Can remove old MTProto/MTG installs before deployment.
- Supports two-stage deployment: OS update → reboot → MTG/AWG install.
- Installs MTG binary from GitHub release with SHA256 verification.
- Runs MTG under a dedicated `mtg` system user through systemd.
- Supports `MASK_DOMAIN`: your own FakeTLS/SNI domain, interactive selection, or random selection from a built-in list.
- Optionally installs AmneziaWG on UDP `443`; MTG can use TCP `443` at the same time.
- Supports custom AmneziaWG subnet through `--awg-subnet`, or random `/24` inside `10.0.0.0/8`.
- Enables UFW firewall with only SSH, MTG TCP port and AWG UDP port allowed.
- Enables unattended system updates and daily MTG update checks.

## Recommended install from GitHub

Download the script first. This is better than `curl | bash`, because reboot-resume needs a local installer file.

```bash
curl -fsSL https://raw.githubusercontent.com/shiirx-sudo/mtproto-proxy-installer/main/install.sh -o /root/mtg-install.sh
chmod +x /root/mtg-install.sh
sudo /root/mtg-install.sh \
  --full \
  --random-mask-domain \
  --port 443 \
  --install-awg \
  --awg-port 443 \
  --enable-firewall \
  --auto-updates \
  --auto-reboot \
  --remove-existing \
  --yes
```

With your own mask domain and AWG subnet:

```bash
sudo /root/mtg-install.sh \
  --full \
  --mask-domain ya.ru \
  --port 443 \
  --install-awg \
  --awg-port 443 \
  --awg-subnet 10.66.66.0/24 \
  --enable-firewall \
  --auto-updates \
  --auto-reboot \
  --remove-existing \
  --yes
```

`--domain` is kept as a legacy alias for `--mask-domain`.

## Manual two-stage install

```bash
sudo ./install.sh --prepare --remove-existing --auto-updates --yes
sudo reboot
sudo ./install.sh --random-mask-domain --port 443 --install-awg --awg-port 443 --enable-firewall --auto-updates --yes
```

## Mask domain selection

If no `--mask-domain` is supplied:

- interactive mode asks whether to enter your own domain or pick a random one;
- `--yes` mode automatically picks a random domain from the built-in list;
- `--random-mask-domain` forces random selection.

Built-in candidates:

```text
max.ru
storage.yandex.net
yastatic.net
ya.ru
vk.com
api.vk.com
userapi.com
vkuservideo.ru
cdnvideo.ru
okcdn.ru
hosting.reg.ru
cdn.ngenix.net
```

The built-in list is tuned for RU-oriented connectivity. You can still override it with any real HTTPS domain using `--mask-domain`.

## AmneziaWG subnet

By default, when `--install-awg` is enabled and no subnet is provided:

- interactive mode asks whether to use a random subnet;
- `--yes` mode automatically picks a random `/24` inside `10.0.0.0/8`.

Example fixed subnet:

```bash
--awg-subnet 10.66.66.0/24
```

Generated addresses:

- server: first host, for example `10.66.66.1/24`;
- first client: second host, for example `10.66.66.2/32`.

The first AmneziaWG client config is saved to:

```text
/root/awg-clients/admin.conf
```

## Management

```bash
sudo mtgctl link
sudo mtgctl status
sudo mtgctl doctor
sudo mtgctl logs
sudo mtgctl update --latest
sudo mtgctl mask-domain ya.ru
sudo mtgctl awg-status
sudo mtgctl awg-client admin
```

## Firewall policy

With `--enable-firewall`:

- default incoming: deny;
- outgoing: allow;
- SSH TCP port is detected through `sshd -T`, fallback is `22/tcp`;
- MTG TCP port is allowed, default `443/tcp`;
- if AmneziaWG is enabled, AWG UDP port is allowed, default `443/udp`.

Using both MTG and AmneziaWG on port number `443` is valid because MTG uses TCP and AWG uses UDP.

## Existing install detection

The installer checks:

- `mtg`, `mtproxy`, `mtproto-proxy`, `MTProxy`, `mtproto_proxy` systemd services;
- `/usr/local/bin/mtg`, `/etc/mtg.toml`, `/etc/mtproxy`, `/etc/mtg`, `/opt/MTProxy`;
- Docker containers/images matching `telegrammessenger/proxy`, `nineseconds/mtg`, `mtproto`, `mtproxy`, `mtg-proxy`.

Removal is intentionally limited to known MTProto/MTG paths and services.

## Notes

- AmneziaWG automatic install targets Ubuntu through `ppa:amnezia/ppa`.
- Automatic system updates do not automatically reboot the server.
- MTG auto-update runs through `mtgctl update --latest` with checksum verification.
- Do not commit real secrets, generated configs or client VPN profiles.
