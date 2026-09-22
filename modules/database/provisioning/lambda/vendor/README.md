# Vendored database drivers

The provisioning Lambda connects to the database, so it needs a driver, and the
Lambda Python runtimes do not include one. `psycopg` would need compiled binaries
built for the runtime's architecture; **pg8000 is pure Python**, so it is simply
committed here and works on any runtime.

| Package | Why |
| --- | --- |
| `pg8000` | the PostgreSQL driver |
| `pymysql` | the MySQL driver. Its optional `cryptography` dependency is not vendored: over TLS, `caching_sha2_password` sends the password through the encrypted channel and needs no RSA |
| `scramp` | SCRAM-SHA-256 authentication, which RDS PostgreSQL requires by default |
| `asn1crypto` | scramp's own dependency |
| `python-dateutil` | pg8000's date parsing |
| `six` | python-dateutil's own dependency |

The Lambda runtime happens to ship `python-dateutil` and `six`, because boto3
depends on them. They are vendored anyway: a function must not rely on the
runtime's copy of anything it did not ask for, since AWS can change it.

All of them are pure Python and carry no compiled extension.

To refresh them:

```bash
pip download --no-deps --only-binary=:all: --python-version 3.14 pg8000 scramp asn1crypto python-dateutil six PyMySQL -d /tmp/wheels
cd /tmp/wheels && for w in *.whl; do unzip -o "$w" -d pkg; done
cp -r pkg/* modules/database/provisioning/lambda/vendor/
```

The `.dist-info` directories are kept on purpose: `pg8000` and `scramp` read their
own version through `importlib.metadata` at import time and fail without them.

Nothing else in this repository imports them.
