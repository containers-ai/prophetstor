# Use a minimal base image with bash
FROM bash:latest

RUN apk add --no-cache coreutils

WORKDIR /root

COPY kubectl /usr/local/bin/
COPY instance-duration-collect.sh .
