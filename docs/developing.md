# Developing

A guide for developing sdfgen. Before reading this, make sure that you
can build the tooling from source by following the top-level README.

## Workflow

The workflow when working on the tooling slightly differs depending on whether
you're working on purely internal changes or changes that affect the C or Python
bindings as well.

After making any changes it is good to run the tests.

For the tests, you will after first initiliase the submodule(s):
```sh
git submodule update --init
```

To run the tests:
```sh
zig build test
```

On success, there should be no output.

To build the C library specifically you want to run:
```sh
zig build c
```

By default, these will always produce debug builds which will have extra printing
and logging.

For release builds, there are different optimisation levels that Zig provides:
* Debug
* ReleaseSafe
* ReleaseFast
* ReleaseSmall

We use ReleaseSafe for release builds which means that certain safety checks are
kept at runtime, e.g:
```sh
zig build c -Doptimize=ReleaseSafe
```

You can read more in the
[Zig docs](https://ziglang.org/documentation/master/#Build-Mode).

When working on C or Python `zig build test` will compile the C bindings as
well.

`tests/` contain the expected output for each test in a `.system` file.
`src/test.zig` contains the code for running each test.

If `zig build test` finishes without outputting anything, all of the tests
passed.

## Python bindings

The Python bindings live in `src/python/`.

There's two files, `__init__.py` and `module.py`. `__init__.py` you should never
have to touch unless you are adding a top-level class (e.g something like Sddf
or LionsOs).

`module.py` contains two parts:
1. Declarations of the C API using `ctypes`.
2. Classes and functions that wrap over the C API.

Before doing any development on `module.py`, it is a good idea to have a quick
look at https://docs.python.org/3/library/ctypes.html as that defines how the
Python FFI works.

At the top of `module.py`, you'll see a large list of function declarations for
the C API. Each one will have the return types (`.restype`) and the arguments
`.argtypes`. It is **very important** that these are correct otherwise you will
get segmentation faults that are difficult to debug.

After making your changes you'll want to re-install the Python package to test
it out with:
```sh
./venv/bin/pip install .
```

### Publishing Python packages

Binary releases of the Python package (known as 'wheels' in the Python universe)
are published to [PyPI](https://pypi.org/project/sdfgen/).

Unlike most Python packages, ours is a bit more complicated because:
1. We depend on an external C library.
2. We are building that external C library via Zig and not a regular C compiler.

These have some consequences, mainly that the regular `setup.py` has a custom
`build_extension` function that calls out to Zig. It calls out to `zig build c`
using the correct output library name/path that the Python packaging
wants to use.

This means that you *must* use Zig to build the Python package from source.

##### Supported versions

We try to support all versions of Python people would want to use, within reason.

Right now, that means CPython 3.9 is the lowest version available. If there is a
missing Python package target (OS, architecture, or version), please open an issue.

##### CI

For the CI, we use [cibuildwheel](https://cibuildwheel.pypa.io/) to
automate the process of building for various architectures/operating systems.

The CI runs on every commit and produces GitHub action artefacts that contain
all the wheels (`*.whl`).

For any new tags to the repository, the CI also uploads a new version of the
package to PyPI automatically. Note that each tag should have a new version in
the `VERSION` file at the root of the source.
See [Making releases](#making-releases) for doing this.

The publishing job works by authenticating the repository's GitHub workflow with
the package on PyPI, there are no tokens etc stored on GitHub.

If you want to support a new OS or achitecture or change the Python versions,
look at `.github/workflows/pysdfgen.yml`.

## Debugging

A common example might be someone ran into a segmentation fault while using the
Python bindings which means there are a couple possibilities:
* the Zig code has a memory safety issue.
* the C bindings have a memory safety issue.
* the Python declarations are wrong.

The first step is to narrow down to which API call(s) is causing the
segmentation fault.

After that, build the Python package in debug mode by doing:
```sh
PYSDFGEN_DEBUG=1 ./venv/bin/pip install .
```

Re-run the program that's causing issues and see if any asserts or panics go
off.

If there are not, your next step is to check:
1. The C API declaration in Python matches the actual declaration.
2. The C API is correctly casting/using and pointers and the Python wrapper is
   passing the right pointers.

## Making releases

There is a script for automating the release process, it creates a new tag
and a corresponding GitHub release for the tag

```sh
# Make sure to run from root of repository
./scripts/release.sh <VERSION>
```

For example running `./scripts/release.sh 0.8.0` will create a tag called
0.8.0 and push it to the repo which will cause the CI to automatically build
and push the Python package to PyPI with version 0.8.0 as well as upload
pre-built versions of the C library.

### Nix

The way Zig compiles code is a bit at odds with Nix. Nix wants to keep track
of all inputs such that it can determinstically check the output, makes sense.

When building the package, Zig will attempt to create cache directories and
fetch the 'dtb.zig' dependency from the network. To get this working with a Nix
output we have to do some annoying extra setup.

In `package.nix` you will see the dependencies listed and calls to `fetchzip`.
What that does is allow us to get the dependency in a way Nix is happy with.

If you update `build.zig.zon` at any point of the release cycle, you must also
update `package.nix`.

#### Updating package.nix

For each dependency:
1. The `name` field should be the Zig hash in `build.zig.zon` for the dependency.
2. The `url` in `fetchzip` should match the `.url` filed in `build.zig.zon`.
3. To get the `hash` field value, run the following commands:
```sh
nix-prefetch-url --unpack <URL>
nix hash convert --hash-algo sha256 --from nix32 <HASH FROM PREFETCH URL>
```
