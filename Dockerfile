# TARGETOS/TARGETARCH are supplied by buildx for multi-architecture builds and
# default to the AKS node architecture for plain Docker and ACR builds.
FROM golang:1.27.3-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /bench ./cmd/bench

FROM alpine:3.24
COPY --from=builder /bench /bench
ENTRYPOINT ["/bench"]
