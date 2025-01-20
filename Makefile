run:
	zig build run -- ./test-db

play:
	zig build play

build:
	zig build install -Doptimize=Debug

test-cli: build
	bundle exec rspec spec/main_spec.rb
	rm -rf test.db

test:
	zig build test

test-all: test test-cli
