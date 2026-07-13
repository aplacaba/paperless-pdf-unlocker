# Build stage: SBCL + Quicklisp → standalone executable
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    sbcl curl ca-certificates build-essential libssl-dev && \
    rm -rf /var/lib/apt/lists/*

RUN curl -sSLO https://beta.quicklisp.org/quicklisp.lisp && \
    sbcl --non-interactive --load quicklisp.lisp \
         --eval '(quicklisp-quickstart:install)' \
         --eval '(quit)' && \
    rm quicklisp.lisp && \
    printf '#-quicklisp\n(let ((qi (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))\n  (when (probe-file qi)\n    (load qi)))\n' > ~/.sbclrc

WORKDIR /app
COPY unlocker.asd ./
COPY src/ src/

# Build the binary
RUN mkdir -p /root/.cache/common-lisp && \
    sbcl --non-interactive \
         --eval '(push "/app/" asdf:*central-registry*)' \
         --eval '(ql:quickload :drakma :silent t)' \
         --eval '(ql:quickload :jonathan :silent t)' \
         --eval '(ql:quickload :unlocker :silent t)' \
         --eval '(sb-ext:save-lisp-and-die "unlocker" :executable t :toplevel (quote unlocker.main:start) :compression t)' \
         --eval '(quit)' && \
    chmod +x unlocker

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    qpdf ca-certificates zlib1g libssl3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/unlocker /app/unlocker

ENV LOCKED_TAG=locked \
    UNLOCK_FAILED_TAG=unlock-failed \
    POLL_INTERVAL_SECONDS=60 \
    HTTP_TIMEOUT_SECONDS=30 \
    LOG_LEVEL=info

ENTRYPOINT ["/app/unlocker"]
