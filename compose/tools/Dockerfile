# ZA Mail tools: one image for setup, provisioning, mirroring, probing and tests.
FROM stalwartlabs/cli:1.0.14 AS cli
FROM alpine:3.22
RUN apk add --no-cache python3 curl jq gettext ca-certificates bash openssl tzdata
COPY --from=cli /usr/local/bin/stalwart-cli /usr/local/bin/stalwart-cli
WORKDIR /zamail
CMD ["sleep", "infinity"]
