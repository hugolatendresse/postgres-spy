# Building PostgreSQL From Source

This guide is for a fresh Ubuntu/Debian EC2 instance after cloning this repository. It builds PostgreSQL with Autoconf and GNU Make, installs it into this checkout, and avoids writing to `/usr/local/pgsql`.

Reference docs:

- Requirements: <https://www.postgresql.org/docs/current/install-requirements.html>
- Autoconf and Make install: <https://www.postgresql.org/docs/current/install-make.html>
- Post-install setup: <https://www.postgresql.org/docs/current/install-post.html>

## Install Build Requirements

From the repository root:

```sh
./rebuild-postgres.sh --install-deps
```

That installs the packages needed for the default PostgreSQL build on Ubuntu/Debian:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  flex \
  bison \
  libreadline-dev \
  zlib1g-dev \
  libicu-dev \
  pkg-config
```

These cover GNU make, a C/C++ compiler, Flex, Bison, Perl, Readline, zlib, ICU, and `pkg-config`. If you enable optional PostgreSQL features later, such as OpenSSL, LZ4, Zstandard, XML, LDAP, PAM, or LLVM JIT, install the matching development packages and pass the relevant `configure` flags.

## Build And Install

For normal local development:

```sh
./rebuild-postgres.sh
```

The script uses:

- Build directory: `build/local`
- Install prefix: `.local/pgsql`
- Compiler flags: `-O2 -g`
- Parallel jobs: `nproc`

The equivalent manual commands are:

```sh
mkdir -p build/local .local
cd build/local
../../configure --prefix="$PWD/../../.local/pgsql" CFLAGS="-O2 -g"
make -j"$(nproc)"
make install
```

Use the local binaries:

```sh
export PATH="$PWD/.local/pgsql/bin:$PATH"
```

## Rebuild After Source Changes

After editing backend code, rerun:

```sh
./rebuild-postgres.sh
```

If you change `configure` options, compiler flags, installed dependencies, or anything `configure` probes, reconfigure:

```sh
./rebuild-postgres.sh --reconfigure
```

Useful variants:

```sh
./rebuild-postgres.sh --clean
./rebuild-postgres.sh --check
CFLAGS="-O3 -g" ./rebuild-postgres.sh --reconfigure
CONFIGURE_FLAGS="--without-icu" ./rebuild-postgres.sh --reconfigure
```

`--check` runs PostgreSQL's regression tests before installing. Run tests as an unprivileged user, not as root.

## Initialize And Start A Local Server

Create a data directory once:

```sh
.local/pgsql/bin/initdb -D .local/data
```

Start PostgreSQL:

```sh
.local/pgsql/bin/pg_ctl -D .local/data -l .local/postgres.log start
```

Create and enter a test database:

```sh
.local/pgsql/bin/createdb bench
.local/pgsql/bin/psql bench
```

Stop the server:

```sh
.local/pgsql/bin/pg_ctl -D .local/data stop
```

Because this install is under the repository, you do not need to set `LD_LIBRARY_PATH` on Linux for this default build. Adding `.local/pgsql/bin` to `PATH` is enough for day-to-day use.

## Quick Timing Setup

Inside `psql bench`, create dummy tables:

```sql
CREATE TABLE scan_dummy AS
SELECT i AS id, repeat('x', 64) AS payload
FROM generate_series(1, 10000000) AS g(i);

CREATE TABLE hash_outer AS
SELECT i AS id, i % 1000000 AS key
FROM generate_series(1, 5000000) AS g(i);

CREATE TABLE hash_inner AS
SELECT i AS key, repeat('y', 32) AS payload
FROM generate_series(0, 999999) AS g(i);

ANALYZE scan_dummy;
ANALYZE hash_outer;
ANALYZE hash_inner;
```

Measure a sequential scan:

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM scan_dummy;
```

Measure a simple hash join:

```sql
SET max_parallel_workers_per_gather = 0;
SET enable_mergejoin = off;
SET enable_nestloop = off;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON)
SELECT count(*)
FROM hash_outer o
JOIN hash_inner i ON i.key = o.key;
```

For wall-clock measurements outside `psql`, use the installed `psql` with `/usr/bin/time`:

```sh
/usr/bin/time -p .local/pgsql/bin/psql bench -c 'SELECT count(*) FROM scan_dummy;'
```

For repeatable comparisons, keep the server settings, data size, warm/cold cache state, and EC2 instance type fixed between runs.
