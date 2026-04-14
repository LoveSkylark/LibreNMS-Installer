# LibreNMS Installer

This repository bootstraps a single-node LibreNMS deployment on K3s, installs helper tooling, and provides shell shortcuts for day-to-day management.

## What gets installed

- K3s
- Helm
- K9s
- SNMP tooling (`snmp`, `snmpd`)
- Profile helpers under `/etc/profile.d/`

## Quick start

1. Run the installer as a user with sudo access:

```bash
chmod +x ./LibreNMS-Install
./LibreNMS-Install
```

2. Open a new shell session (or source `/etc/profile.d/*.sh`).
3. Start LibreNMS:

```bash
nms start
```

4. Verify pod status:

```bash
nms status
```

## Important paths

- Main data directory: `${LNMS_DIR:-/data}`
- Runtime values file: `${LNMS_DIR:-/data}/lnms-config.yaml`
- Chart clone path: `${LNMS_DIR:-/data}/vault/LibreNMS-Helm`

## Common commands

- `nms start` Install LibreNMS release
- `nms stop` Uninstall LibreNMS release
- `nms edit` Edit values file and apply upgrade
- `nms update` Apply Helm upgrade from current values
- `nms preflight` Validate dependencies, chart path, values file, and cluster reachability
- `nms status` Describe LibreNMS app pod
- `nms monitor` Open K9s
- `nms map` Run Weathermap poller inside app pod
- `nms cert <cert> <key>` Create/update TLS secret `https-cert` in namespace `librenms`
- `nms help` Print local command help

Automation options for `start` and `edit`:

- `--non-interactive` or `-n` Skip opening `vim`
- `--no-auto-add-host` Skip automatic `lnms device:add` for the local host

Environment variable overrides:

- `NMS_NO_EDITOR=1`
- `NMS_AUTO_ADD_HOST=0`
- `NMS_HOST_IP=<ip>` force the IP used for auto host add

## Notes

- The installer is designed to be idempotent for clone/copy steps.
- Helm operations use namespace `librenms`.
- Update placeholders in `config/lnms-config.yaml` before production use.