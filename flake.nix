{
  description = "ReactOS build environment (i686 MinGW cross toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.cmake
            pkgs.ninja
            pkgs.bison
            pkgs.flex
            pkgs.python3
            # Provides i686-w64-mingw32-{gcc,g++,windres,windmc,dlltool,objcopy}
            pkgs.pkgsCross.mingw32.buildPackages.gcc
          ];

          ROS_ARCH = "i386";
        };
      });
    };
}
