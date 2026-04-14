## Configuration Overview

- `lnms-config.yaml`: main values file used by Helm for install and upgrade.
- `authentication/*.php`: optional static LibreNMS auth overrides.
- `weathermap/example.conf`: sample Weathermap configuration template.

## How values are applied

- The installer copies `lnms-config.yaml` to `${LNMS_DIR:-/data}/lnms-config.yaml` on first run.
- `nms start`, `nms edit`, and `nms update` use that runtime file.

## Security guidance

- Replace all placeholder credentials before production use.
- Keep auth override PHP files out of world-readable paths.
- Treat this repository as templates, not a secret store.
