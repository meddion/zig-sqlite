# Zig DB

A lightweight, SQLite-like database implemented from scratch in the Zig programming language. This project is for educational purposes to understand the internals of a simple database.

This project was greatly inspired by the guide in [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/).

## Getting Started

### Prerequisites

*   [Zig](https://ziglang.org/)
*   [Make](https://www.gnu.org/software/make/)
*   [Ruby](https://www.ruby-lang.org/en/) and [Bundler](https://bundler.io/) (for running the CLI tests)

### Building the Project

To build the executable, run:

```sh
make build
```

### Running the CLI

To start the database CLI, run:

```sh
make run
```

This will create a database file named `test-db` in the root directory if one doesn't exist.

## Testing

The project has both unit tests and integration tests for the CLI.

### Running Unit Tests

To run the unit tests written in Zig, use:

```sh
make test
```

### Running CLI Tests

To run the RSpec tests for the command-line interface, use:

```sh
make test-cli
```

### Running All Tests

To run all tests, use:

```sh
make test-all
```

## Project Structure

```
.
├── Makefile
├── build.zig
├── spec
│   └── main_spec.rb
└── src
    ├── btree.zig
    ├── cmd_handler.zig
    ├── db.zig
    ├── input.zig
    ├── main.zig
    ├── pager.zig
    ├── playground.zig
    ├── row.zig
    ├── table.zig
    ├── tests.zig
    └── utils.zig
```

*   `src/`: Contains the core source code for the database.
    *   `main.zig`: The main entry point for the CLI application.
    *   `db.zig`: Core database logic.
    *   `btree.zig`: B-tree implementation for indexing.
    *   `pager.zig`: Manages reading and writing of database pages.
    *   `table.zig`, `row.zig`: Data structures for tables and rows.
    *   `tests.zig`: Unit tests.
*   `spec/`: Contains the RSpec tests for the CLI.
*   `build.zig`: The build script for the project.
*   `Makefile`: Contains helper commands for building, running, and testing the project.
