FROM alpine:3.24
RUN apk add --no-cache jq kubectl
COPY deploy/aks/run-nine-attempts.sh /usr/local/bin/run-nine-attempts
RUN chmod 0555 /usr/local/bin/run-nine-attempts
ENV HOME=/tmp
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/run-nine-attempts"]
