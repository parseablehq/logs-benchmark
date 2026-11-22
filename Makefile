IMAGE_REPO ?= logs-benchmark
TAG ?= dev

.PHONY: build test fmt vet check-all image

build:
	go build -o bin/bench ./cmd/bench

test:
	go test ./...

fmt:
	gofmt -l -w -s ./cmd ./internal

vet:
	go vet ./...

check-all: fmt vet

image:
	docker build -t $(IMAGE_REPO):$(TAG) .
