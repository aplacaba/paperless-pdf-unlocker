# paperless-pdf-unlocker

Poll a Paperless-ngx instance for user-password-encrypted PDFs, decrypt them with `qpdf`
using a configurable list of candidate passwords, and replace each original with an
unlocked copy that preserves the original's metadata.

Built in Common Lisp (SBCL). Deployable as a Docker container.

## Build & Run

```sh
docker build -t unlocker .
cp docker-compose.example.yml docker-compose.yml
# edit PAPERLESS_URL, PAPERLESS_TOKEN, PASSWORD_CANDIDATES
docker compose up -d
```

## Configuration

All via environment variables. See `docker-compose.example.yml`.

## Tests

```sh
sbcl --eval '(push (truename ".") asdf:*central-registry*)' --eval '(asdf:test-system :unlocker)'
```

Requires SBCL, Quicklisp (drakma, jonathan, rove), and `qpdf`.
