.PHONY: all build clean install test

all: build

build:
	go build -o service-operator

clean:
	rm -f service-operator

install: build
	go install

test:
	go test ./...