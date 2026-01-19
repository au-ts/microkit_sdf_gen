import os
from setuptools.command.build_ext import build_ext
from setuptools import setup, Extension, find_packages
from pathlib import Path

csdfgen = Extension("csdfgen", sources=[], depends=["src/c/sdfgen.h"], include_dirs=["src/c/"])

with open("VERSION", "r") as f:
    version = f.read()

class ZigBuilder(build_ext):
    def build_extension(self, ext):
        modpath = self.get_ext_fullpath(ext.name).split('/')
        modpath = os.path.abspath('/'.join(modpath[0:-1]))

        optimize = "Debug" if os.environ.get("PYSDFGEN_DEBUG", '0') != '0' else "ReleaseSafe"
        print("optimize:", optimize)

        args = [
            "zig",
            "build",
            "c",
            f"-Doptimize={optimize}",
            # Python expects us to always provide a dynamic library
            "-Dc-linkage=dynamic",
            f"-Dc-emit={self.get_ext_filename(ext.name)}",
            "-freference-trace=13",
            "--prefix-lib-dir",
            f"{modpath}",
        ]

        self.spawn(args)


setup(
    name="sdfgen",
    version=version,
    url="https://github.com/au-ts/microkit_sdf_gen",
    description="Automating the creation of Microkit System Description Files (SDF)",
    packages=["sdfgen"],
    package_dir={
        "sdfgen": "./src/python"
    },
    # Necessary for mypy to work for those that import the package
    package_data={"sdfgen": ["py.typed"]},
    ext_modules=[csdfgen],
    cmdclass={"build_ext": ZigBuilder},
    long_description=(Path(__file__).parent / "README.md").read_text(encoding="utf-8"),
    long_description_content_type="text/markdown",
)
