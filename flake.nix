# ReactOS build environment.
#
#   nix develop
#   ./configure.sh                 # creates output-MinGW-i386 (Debug, i386)
#   cd output-MinGW-i386
#   ninja bootcd                   # -> output-MinGW-i386/bootcd.iso
#
# The first `nix develop` builds the cross GCC below from source.
{
  description = "ReactOS build environment (i686 MinGW cross toolchain)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # i686-w64-mingw32 GCC configured like RosBE's: win32 threads, SJLJ
      # exceptions, static runtime only. The stock nixpkgs MinGW GCC uses the
      # mcf thread model, whose libgcc/libsupc++ need mcfgthread symbols that
      # ReactOS does not provide.
      #
      # ReactOS links libgcc/libsupc++/libstdc++ from the toolchain against its
      # own NT 5.2 kernel32 and msvcrt, so the target libraries are built the
      # way RosBE's older mingw-w64 headers would have built them:
      #  - _WIN32_WINNT=0x0502: no Vista condition variables in gthr-win32.
      #  - __USE_MINGW_ANSI_STDIO=0: no __mingw_sprintf in the demangler.
      #  - glibcxx_cv_LFS=no: no fseeko64/ftello64, which ReactOS's msvcrt
      #    import library does not export.
      #  - glibcxx_cv_S_IS/IFREG=no: no fstat32 in __basic_file::showmanyc.
      rosGcc = pkgs:
        let
          cross = pkgs.pkgsCross.mingw32.buildPackages;
          mingw = pkgs.pkgsCross.mingw32.windows.mingw_w64;

          # mingw-w64 >= 8 moved the C95 wide-char emulations libstdc++ needs
          # (mbrtowc, wcrtomb, wctype) from libmingwex into its own libmsvcrt.a,
          # which ReactOS replaces with its own import library. Put them back
          # into libmingwex, as in the mingw-w64 6.0 that RosBE ships.
          libc = pkgs.runCommand "mingw-w64-reactos" {
            nativeBuildInputs = [ cross.binutils-unwrapped ];
          } ''
            mkdir -p $out/lib work
            ln -s ${pkgs.lib.getDev mingw}/include $out/include
            ln -s ${mingw}/lib/* $out/lib/
            rm $out/lib/libmingwex.a
            cp ${mingw}/lib/libmingwex.a $out/lib/libmingwex.a
            chmod u+w $out/lib/libmingwex.a
            cd work
            i686-w64-mingw32-ar x ${mingw}/lib/libmsvcrt.a \
              lib32_libmsvcrt_common_a-mbrtowc.o \
              lib32_libmsvcrt_common_a-wcrtomb.o \
              lib32_libmsvcrt_common_a-__mingw_mbrtowc_cp.o \
              lib32_libmsvcrt_common_a-__mingw_wcrtomb_cp.o \
              lib32_libmsvcrt_common_a-__mingw_isleadbyte_cp.o \
              lib32_libmsvcrt_extra_a-wctype.o
            i686-w64-mingw32-ar rs $out/lib/libmingwex.a *.o
          '';

          cc = (cross.gcc13.cc.override {
            threadsCross = { model = "win32"; package = null; };
            enableShared = false;
          }).overrideAttrs (old: {
            configureFlags =
              pkgs.lib.subtractLists [ "--disable-sjlj-exceptions" "--with-dwarf2" ] old.configureFlags
              ++ [ "--enable-sjlj-exceptions" ];
            # With _WIN32_WINNT < 0x0600 the win32 gthreads have no std::mutex,
            # but tzdb.cc only checks __GTHREADS. Make it use its no-op mutex.
            postPatch = (old.postPatch or "") + ''
              substituteInPlace libstdc++-v3/src/c++20/tzdb.cc \
                --replace-fail '#if defined __GTHREADS &&' '#if defined _GLIBCXX_HAS_GTHREADS &&' \
                --replace-fail '#ifndef __GTHREADS' '#ifndef _GLIBCXX_HAS_GTHREADS'
            '';
            env = old.env // {
              EXTRA_FLAGS_FOR_TARGET =
                old.env.EXTRA_FLAGS_FOR_TARGET + " -D_WIN32_WINNT=0x0502 -D__USE_MINGW_ANSI_STDIO=0";
              glibcxx_cv_LFS = "no";
              glibcxx_cv_S_ISREG = "no";
              glibcxx_cv_S_IFREG = "no";
            };
          });
        in
        cross.wrapCCWith {
          inherit cc libc;
          bintools = cross.wrapBintoolsWith { bintools = cross.binutils-unwrapped; inherit libc; };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        gcc = rosGcc pkgs;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.cmake
            pkgs.ninja
            pkgs.bison
            pkgs.flex
            pkgs.python3
            # Provides i686-w64-mingw32-{gcc,g++,windres,windmc,dlltool,objcopy}
            (rosGcc pkgs)
          ];

          # The cc-wrapper's hardening flags (-Werror=format-security,
          # -fstack-protector, _FORTIFY_SOURCE...) break the freestanding build.
          hardeningDisable = [ "all" ];

          # GCC 13 -Wall flags two spots that RosBE's GCC 8.4 accepts (freetype
          # ftlcdfil.c, netcfgx tcpipconf_notify.c). Keep only those non-fatal.
          # CMake reads this into CMAKE_C_FLAGS on the first configure.
          CFLAGS = "-Wno-error=array-parameter -Wno-error=misleading-indentation";

          ROS_ARCH = "i386";
        };
      });
    };
}
