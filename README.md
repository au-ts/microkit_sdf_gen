# Higher-level tooling for constructing seL4 Microkit systems

This repository currently holds various programs to help with automating the
process of creating seL4 Microkit systems.

> [!IMPORTANT] This project is experimental, we are using it
> internally to get it into a usable state for the public. For
> development this work exists in a separate repository, but that may
> change once it has matured (e.g by being apart of the official
> Microkit repository).

## Problem

In order to remain simple, the seL4 Microkit (intentionally) does not
provide one-size-fits-all abstractions for creating systems where the
information about the design of the system flows into the actual code
of the system.

A concrete example of this might be say some code that needs to know
how many clients it needs to serve. This obviously depends on the
system designer, and could easily be something that changes for
different configurations of the same system. The Microkit SDF offers
no way to pass down this kind of information. For the example
described, an easy 'solution' would be to pass some kind of
compile-time parameter (e.g a #define in C) for the number of
clients. However imagine now you have the same system with two
configurations, with two clients and one with three, this requires two
separate SDF files even though they are very similar systems and the
code remains identical expect for the compile-time parameter. This
problem ultimately hampers experimentation.

Another 'problem' with SDF is that is verbose and descriptive. I say
'problem' as the verbosity of it makes it an ideal source of truth for
the design of the system and hides minimal information as to the
capability distribution and access policy of a system. But the
negative of this is that it does not scale well, even small changes to
a large SDF file are difficult to make and ensure are correct.

## Solution(s)

* Allow for users to easily auto-generate SDF programmatically using a
  tool called `sdfgen`. 
* Create a graphical user-interface to visually display and
  produce/maintain the design of a Microkit s ystem.
  This graphical user-interface will sort of act as a 'frontend' for
  the `sdfgen` tool. 

Both of these solutions are very much in a work-in-progress state.

## Developing

All the tooling is currently written in
[Zig](https://ziglang.org/download/) with bindings for other languages
available.

### Dependencies

There are two dependencies:

* Zig (`0.14.0-dev.2079+ba2d00663` or higher)
  * See https://ziglang.org/download/, until 0.14.0 is released we
    rely on a master version of Zig.
    Once 0.14.0 is released (most likely in a couple of months) we can
    pin to that release.
* Device Tree Compiler (dtc)

### Tests

To test the Zig and C bindings, you can run:
```sh
zig build test
```

### Zig bindings

The source code for the sdfgen tooling is written in Zig, and so we
simply expose a module called
`sdf` in `build.zig`.

To build and run an example of the Zig bindings being used run:
```sh
zig build zig_example -- --example webserver --board qemu_virt_aarch64
```

The source code is in `examples/examples.zig`.

To see all the options run:
```sh
zig build zig_example -- --help
```

### C bindings

```sh
zig build c
```

The library will be at `zig-out/lib/csdfgen`.

The source code for the bindings is in `src/c/`.

To run an example C program that uses the bindings, run:
```sh
zig build c_example
```

The source code for the example is in `examples/examples.c`.

### Python bindings

The Python package is supported for versions 3.9 to 3.13.  Linux
(x86-64) and macOS (Intel/Apple Silicon) are supported. Windows is
*not* supported.

The Python bindings are all in Python itself, and do direct FFI to the
C bindings via
[ctypes](https://docs.python.org/3/library/ctypes.html).

#### Building the package

To build a usable Python package run the following:
```sh
python3 -m venv venv
./venv/bin/python3 -m pip install .
```

Now you should be able to import and use the bindings:
```sh
./venv/bin/python3
>>> import sdfgen
>>> help(sdfgen)
```

#### Publishing Python packages

Binary releases of the Python package (known as 'wheels' in the Python
universe) are published to [PyPI](https://pypi.org/project/sdfgen/).

Unlike most Python packages, ours is a bit more complicated because:
1. We depend on an external C library.
2. We are building that external C library via Zig and not a regular C
   compiler.

These have some consequences, mainly that the regular `setup.py` has a
custom `build_extension` function that calls out to Zig. It calls out
to `zig build c` using the correct output library name/path that the
Python packaging wants to use.

This means that you *must* use Zig to build the Python package from source.

##### Supported versions

We try to support all versions of Python people would want to use,
within reason.

Right now, that means CPython 3.9 is the lowest version available. If
there is a missing Python package target (OS, architecture, or
version), please open an issue.

##### CI

For the CI, we use [cibuildwheel](https://cibuildwheel.pypa.io/) to
automate the process of building for various architectures/operating
systems.

The CI runs on every commit and produces GitHub action artefacts that
contain all the wheels (`*.whl`).

For any new tags to the repository, the CI also uploads a new version
of the package to PyPI automatically.  Note that each tag should have
a new version in the `VERSION` file at the root of the source. See
[scripts/README.md](scripts/README.md) for doing this.

The publishing job works by authenticating the repository's GitHub
workflow with the package on PyPI, there are no tokens etc stored on
GitHub.
