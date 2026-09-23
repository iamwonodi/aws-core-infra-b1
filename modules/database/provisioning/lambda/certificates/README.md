# Amazon RDS certificate bundle

The provisioning function verifies every database's TLS certificate, and its host name, against the certificate authorities in `rds-global-bundle.pem`. RDS (PostgreSQL, MySQL) and DocumentDB sign with the same authorities, so this one file serves all three engines.

**Without the file the function refuses to connect.** It never falls back to an unverified connection.

## Getting it

AWS publishes the bundle over HTTPS. Download it from AWS itself, not from a copy elsewhere, and commit it:

```powershell
Invoke-WebRequest -Uri "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem" `
  -OutFile "modules/database/provisioning/lambda/certificates/rds-global-bundle.pem"
```

```bash
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o modules/database/provisioning/lambda/certificates/rds-global-bundle.pem
```

The global bundle covers every Region, so a copy of this blueprint in any Region uses the same file.

## Checking it

`scripts/ci/check-ca-bundle.sh` (run in CI) fails if the file is missing, empty, or contains anything but certificates.

## Refreshing it

AWS adds authorities as it rotates them, well before old ones expire, and announces rotations. Download the bundle again when it does, or once a year, and commit the change; a new bundle only adds trust in AWS's own authorities.
