#
# Copyright 2024, UNSW
# SPDX-License-Identifier: BSD-2-Clause
#
{
  zig
, nix-gitignore
, pythonPackages
, lib
, linkFarm
, fetchzip
}:

  let deps = linkFarm "zig-packages" [
    {
      name = "dtb-0.0.0-gULdmT8JAgAO49xxrRGA_0_0v4nPL7D91Ev2x7NnNbmy";
      path = fetchzip {
        url = "https://github.com/Ivan-Velickovic/dtb.zig/archive/13d4cc60806f4655043d00df50d4225737b268d4.tar.gz";
        hash = "sha256-V5L3/B7mQ6OubTyIUbHDxGJSm+pbIYcoyJcOAReMhTk=";
      };
    }
    {
      name = "sddf-0.0.0-6aJ67hfnZgCIb73S-PWM-oHDp0RadrbTQqB2Cc7wDlln";
      path = fetchzip {
        url = "https://github.com/au-ts/sddf/archive/e8341acea643c818e59033812accdc531fb82201.tar.gz";
        hash = "sha256-0PEHzD5mkCkRK3LJ8exkJi3rgzr3ZS8UzE9V3OonA1g=";
      };
    }
  ];
in
  with pythonPackages;
    buildPythonPackage rec {
      pname = "sdfgen";
      version = builtins.readFile ./VERSION;
      src = nix-gitignore.gitignoreSource [] ./.;

      build-system = [ setuptools ];
      pyproject = true;

      pythonImportsCheck = [ "sdfgen" ];

      meta = with lib; {
        homepage = "https://github.com/au-ts/microkit_sdf_gen";
        maintainers = with maintainers; [ au-ts ];
      };

      postPatch = ''
        export ZIG_LOCAL_CACHE_DIR=$(mktemp -d)
        export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
        ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
      '';

      nativeBuildInputs = [ zig ];
    }
