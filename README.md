# sdfgen

This repository currently holds libraries to make it easier to develop seL4
Microkit-based systems.

> [!IMPORTANT]
> This project is experimental, we are using it internally to get it into a
> usable state for the public. For development this work exists in a separate
> repository, but that may change once it has matured (e.g by the Microkit part
> of the tooling part of the official Microkit repository, the sDDF part being
> in the sDDF repository, etc).

## Use

The sdfgen tooling (name temporary) contains libraries for programmatically
creating:

* Microkit System Description Files (SDF)
* systems using the seL4 Device Driver Framework (sDDF)
* systems using LionsOS

It has first-class support for use in the following languages:

* C
* Python
* Zig

The Python package is available via `pip`
(on [PyPI](https://pypi.org/project/sdfgen/)) and can be installed simply via
`pip install sdfgen`.

Documentation for the Python package can be found
[here](https://au-ts.github.io/microkit_sdf_gen).

Pre-built archives of the C library are available in each
[release](https://github.com/au-ts/microkit_sdf_gen/releases).

## Building from source

### Dependencies

* [Zig 0.15.x](https://ziglang.org/download)

### C library (libcsdfgen)

The C library can be built with:
```sh
zig build c
```

The library will be in `zig-out/lib/` and the include headers will be in
`zig-out/include/`. On Linux we default to a static binary for the C library,
if you want a dynamic library you can add the `-Dc-dynamic=true` option.

If you want to output the artefacts to a specific directory, you can so with:
```sh
zig build c -p <install dir>
```

### Python

The Python package is supported for versions 3.9 to 3.13.
Linux (x86-64) and macOS (Intel/Apple Silicon) are supported.

To build a usable Python package run the following:
```sh
python3 -m venv venv
./venv/bin/pip install .
```

Now you should be able to import and use the bindings:
```sh
./venv/bin/python3
>>> import sdfgen
>>> help(sdfgen)
```

### Zig

With Zig you will add this repository to your `build.zig.zon` either
via a URL or path depending on your preference, and then change your
`build.zig` to include the `sdf` module.

## Developing

If you want to modify the tooling, please look at
[docs/developing.md](docs/developing.md).

## Motivation

### Problem

In order to remain simple, the seL4 Microkit (intentionally) does not provide
one-size-fits-all abstractions for creating systems where the information about
the design of the system flows into the actual code of the system.

A concrete example of this might be say some code that needs to know how many
clients it needs to serve. This obviously depends on the system designer, and
could easily be something that changes for different configurations of the same
system. The Microkit SDF offers no way to pass down this kind of information.
For the example described, an easy 'solution' would be to pass some kind of
compile-time parameter (e.g a #define in C) for the number of clients. However
imagine now you have the same system with two configurations, with two clients
and one with three, this requires two separate SDF files even though they are
very similar systems and the code remains identical expect for the compile-time
parameter. This problem ultimately hampers experimentation.

Another 'problem' with SDF is that is verbose and descriptive. I say 'problem'
as the verbosity of it makes it an ideal source of truth for the design of the
system and hides minimal information as to the capability distribution and
access policy of a system. But the negative of this is that it does not scale
well, even small changes to a large SDF file are difficult to make and ensure
are correct.

### Solution(s)

* Allow for users to easily auto-generate SDF programmatically using a tool
  called `sdfgen`.
* Create a graphical user-interface to visually display and produce/maintain
  the design of a Microkit system. This graphical user-interface will sort of
  act as a 'frontend' for the `sdfgen` tool.

The `sdfgen` tooling is available and being used by sDDF and LionsOS, although
still experimental. The GUI for the tooling is still very much a
work-in-progress and not ready for use.



