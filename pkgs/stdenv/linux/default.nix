# This file constructs the standard build environment for the
# Linux platform.  It's completely pure; that is, it relies on no
# external (non-Nix) tools, such as /usr/bin/gcc, and it contains a C
# compiler and linker that do not search in default locations,
# ensuring purity of components produced by it.
#
# It starts from prebuilt seed bootstrapFiles and creates a series of
# nixpkgs instances (stages) to gradually rebuild stdenv, which
# is used to build all other packages (including the bootstrapFiles).
#
# Goals of the bootstrap process:
# 1. final stdenv must not reference any of the bootstrap files.
# 2. final stdenv must not contain any of the bootstrap files
#    (the only current violation is libgcc_s.so in glibc).
# 3. final stdenv must not contain any of the files directly
#    generated by the bootstrap code generators (assembler, linker,
#    compiler). The only current violations are: libgcc_s.so in glibc,
#    the lib{mpfr,mpc,gmp,isl} which are statically linked
#    into the final gcc).
#
# These goals ensure that final packages and final stdenv are built
# exclusively using nixpkgs package definitions and don't depend
# on bootstrapTools (via direct references, inclusion
# of copied code, or code compiled directly by bootstrapTools).
#
# Stages are described below along with their definitions.
#
# Debugging stdenv dependency graph:
# An useful tool to explore dependencies across stages is to use
# '__bootPackages' attribute of 'stdenv. Examples of last 3 stages:
# - stdenv
# - stdenv.__bootPackages.stdenv
# - stdenv.__bootPackages.stdenv.__bootPackages.stdenv
# - ... and so on.
#
# To explore build-time dependencies in graphical form one can use
# the following:
#     $ nix-store --query --graph $(nix-instantiate -A stdenv) |
#         grep -P -v '[.]sh|[.]patch|bash|[.]tar' | # avoid clutter
#         dot -Tsvg > stdenv-final.svg
#
# To find all the packages built by a particular stdenv instance:
#    $ for stage in 0 1 2 3 4; do
#      echo "stage${stage} used in:"
#      nix-store --query --graph $(nix-instantiate -A stdenv) |
#          grep -P ".*bootstrap-stage${stage}-stdenv.*->.*" |
#          sed 's/"[0-9a-z]\{32\}-/"/g'
#      done
#
# To verify which stdenv was used to build a given final package:
#     $ nix-store --query --graph $(nix-instantiate -A stdenv) |
#       grep -P -v '[.]sh|[.]patch|bash|[.]tar' |
#       grep -P '.*stdenv.*->.*glibc-2'
#     "...-bootstrap-stage2-stdenv-linux.drv" -> "...-glibc-2.35-224.drv";
#
# For a TUI (rather than CLI) view, you can use:
#
#     $ nix-tree --derivation $(nix-instantiate -A stdenv)
{ lib
, localSystem, crossSystem, config, overlays, crossOverlays ? []

, bootstrapFiles ?
  let table = {
    glibc = {
      i686-linux = import ./bootstrap-files/i686.nix;
      x86_64-linux = import ./bootstrap-files/x86_64.nix;
      armv5tel-linux = import ./bootstrap-files/armv5tel.nix;
      armv6l-linux = import ./bootstrap-files/armv6l.nix;
      armv7l-linux = import ./bootstrap-files/armv7l.nix;
      aarch64-linux = import ./bootstrap-files/aarch64.nix;
      mipsel-linux = import ./bootstrap-files/loongson2f.nix;
      mips64el-linux = import ./bootstrap-files/mips64el.nix;
      powerpc64le-linux = import ./bootstrap-files/powerpc64le.nix;
      riscv64-linux = import ./bootstrap-files/riscv64.nix;
    };
    musl = {
      aarch64-linux = import ./bootstrap-files/aarch64-musl.nix;
      armv6l-linux  = import ./bootstrap-files/armv6l-musl.nix;
      x86_64-linux  = import ./bootstrap-files/x86_64-musl.nix;
    };
  };

  # Try to find an architecture compatible with our current system. We
  # just try every bootstrap we’ve got and test to see if it is
  # compatible with or current architecture.
  getCompatibleTools = lib.foldl (v: system:
    if v != null then v
    else if localSystem.canExecute (lib.systems.elaborate { inherit system; }) then archLookupTable.${system}
    else null) null (lib.attrNames archLookupTable);

  archLookupTable = table.${localSystem.libc}
    or (abort "unsupported libc for the pure Linux stdenv");
  files = archLookupTable.${localSystem.system} or (if getCompatibleTools != null then getCompatibleTools
    else (abort "unsupported platform for the pure Linux stdenv"));
  in files
}:

assert crossSystem == localSystem;

let
  inherit (localSystem) system;

  commonPreHook =
    ''
      export NIX_ENFORCE_PURITY="''${NIX_ENFORCE_PURITY-1}"
      export NIX_ENFORCE_NO_NATIVE="''${NIX_ENFORCE_NO_NATIVE-1}"
      ${if system == "x86_64-linux" then "NIX_LIB64_IN_SELF_RPATH=1" else ""}
      ${if system == "mipsel-linux" then "NIX_LIB32_IN_SELF_RPATH=1" else ""}
    '';


  # The bootstrap process proceeds in several steps.


  # Create a standard environment by downloading pre-built binaries of
  # coreutils, GCC, etc.


  # Download and unpack the bootstrap tools (coreutils, GCC, Glibc, ...).
  bootstrapTools = import (if localSystem.libc == "musl" then ./bootstrap-tools-musl else ./bootstrap-tools) {
    inherit system bootstrapFiles;
    extraAttrs = lib.optionalAttrs
      config.contentAddressedByDefault
      {
        __contentAddressed = true;
        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
      };
  };

  getLibc = stage: stage.${localSystem.libc};


  # This function builds the various standard environments used during
  # the bootstrap.  In all stages, we build an stdenv and the package
  # set that can be built with that stdenv.
  stageFun = prevStage:
    { name, overrides ? (self: super: {}), extraNativeBuildInputs ? [] }:

    let

      thisStdenv = import ../generic {
        name = "${name}-stdenv-linux";
        buildPlatform = localSystem;
        hostPlatform = localSystem;
        targetPlatform = localSystem;
        inherit config extraNativeBuildInputs;
        preHook =
          ''
            # Don't patch #!/interpreter because it leads to retained
            # dependencies on the bootstrapTools in the final stdenv.
            dontPatchShebangs=1
            ${commonPreHook}
          '';
        shell = "${bootstrapTools}/bin/bash";
        initialPath = [bootstrapTools];

        fetchurlBoot = import ../../build-support/fetchurl/boot.nix {
          inherit system;
        };

        cc = if prevStage.gcc-unwrapped == null
             then null
             else lib.makeOverridable (import ../../build-support/cc-wrapper) {
          name = "${name}-gcc-wrapper";
          nativeTools = false;
          nativeLibc = false;
          buildPackages = lib.optionalAttrs (prevStage ? stdenv) {
            inherit (prevStage) stdenv;
          };
          cc = prevStage.gcc-unwrapped;
          bintools = prevStage.binutils;
          isGNU = true;
          libc = getLibc prevStage;
          inherit lib;
          inherit (prevStage) coreutils gnugrep;
          stdenvNoCC = prevStage.ccWrapperStdenv;
        };

        overrides = self: super: (overrides self super) // { fetchurl = thisStdenv.fetchurlBoot; };
      };

    in {
      inherit config overlays;
      stdenv = thisStdenv;
    };

in

[

  ({}: {
    __raw = true;

    gcc-unwrapped = null;
    binutils = null;
    coreutils = null;
    gnugrep = null;
  })

  # Build a dummy stdenv with no GCC or working fetchurl.  This is
  # because we need a stdenv to build the GCC wrapper and fetchurl.
  #
  # resulting stage0 stdenv:
  # - coreutils, binutils, glibc, gcc: from bootstrapFiles
  (prevStage: stageFun prevStage {
    name = "bootstrap-stage0";

    overrides = self: super: {
      # We thread stage0's stdenv through under this name so downstream stages
      # can use it for wrapping gcc too. This way, downstream stages don't need
      # to refer to this stage directly, which violates the principle that each
      # stage should only access the stage that came before it.
      ccWrapperStdenv = self.stdenv;
      # The Glibc include directory cannot have the same prefix as the
      # GCC include directory, since GCC gets confused otherwise (it
      # will search the Glibc headers before the GCC headers).  So
      # create a dummy Glibc here, which will be used in the stdenv of
      # stage1.
      ${localSystem.libc} = self.stdenv.mkDerivation {
        pname = "bootstrap-stage0-${localSystem.libc}";
        strictDeps = true;
        version = "bootstrap";
        enableParallelBuilding = true;
        buildCommand = ''
          mkdir -p $out
          ln -s ${bootstrapTools}/lib $out/lib
        '' + lib.optionalString (localSystem.libc == "glibc") ''
          ln -s ${bootstrapTools}/include-glibc $out/include
        '' + lib.optionalString (localSystem.libc == "musl") ''
          ln -s ${bootstrapTools}/include-libc $out/include
        '';
      };
      gcc-unwrapped = bootstrapTools;
      binutils = import ../../build-support/bintools-wrapper {
        name = "bootstrap-stage0-binutils-wrapper";
        nativeTools = false;
        nativeLibc = false;
        buildPackages = { };
        libc = getLibc self;
        inherit lib;
        inherit (self) stdenvNoCC coreutils gnugrep;
        bintools = bootstrapTools;
      };
      coreutils = bootstrapTools;
      gnugrep = bootstrapTools;
    };
  })


  # Create the first "real" standard environment.  This one consists
  # of bootstrap tools only, and a minimal Glibc to keep the GCC
  # configure script happy.
  #
  # For clarity, we only use the previous stage when specifying these
  # stages.  So stageN should only ever have references for stage{N-1}.
  #
  # If we ever need to use a package from more than one stage back, we
  # simply re-export those packages in the middle stage(s) using the
  # overrides attribute and the inherit syntax.
  #
  # resulting stage1 stdenv:
  # - coreutils, binutils, glibc, gcc: from bootstrapFiles
  (prevStage: stageFun prevStage {
    name = "bootstrap-stage1";

    # Rebuild binutils to use from stage2 onwards.
    overrides = self: super: {
      binutils-unwrapped = super.binutils-unwrapped.override {
        enableGold = false;
      };
      inherit (prevStage)
        ccWrapperStdenv
        gcc-unwrapped coreutils gnugrep;

      ${localSystem.libc} = getLibc prevStage;

      # A threaded perl build needs glibc/libpthread_nonshared.a,
      # which is not included in bootstrapTools, so disable threading.
      # This is not an issue for the final stdenv, because this perl
      # won't be included in the final stdenv and won't be exported to
      # top-level pkgs as an override either.
      perl = super.perl.override { enableThreading = false; enableCrypt = false; };
    };
  })


  # 2nd stdenv that contains our own rebuilt binutils and is used for
  # compiling our own Glibc.
  #
  # resulting stage2 stdenv:
  # - coreutils, glibc, gcc: from bootstrapFiles
  # - binutils: from nixpkgs, built by bootstrapFiles toolchain
  (prevStage: stageFun prevStage {
    name = "bootstrap-stage2";

    overrides = self: super: {
      inherit (prevStage)
        ccWrapperStdenv
        gcc-unwrapped coreutils gnugrep
        perl gnum4 bison;
      dejagnu = super.dejagnu.overrideAttrs (a: { doCheck = false; } );

      # We need libidn2 and its dependency libunistring as glibc dependency.
      # To avoid the cycle, we build against bootstrap libc, nuke references,
      # and use the result as input for our final glibc.  We also pass this pair
      # through, so the final package-set uses exactly the same builds.
      libunistring = super.libunistring.overrideAttrs (attrs: {
        postFixup = attrs.postFixup or "" + ''
          ${self.nukeReferences}/bin/nuke-refs "$out"/lib/lib*.so.*.*
        '';
        # Apparently iconv won't work with bootstrap glibc, but it will be used
        # with glibc built later where we keep *this* build of libunistring,
        # so we need to trick it into supporting libiconv.
        am_cv_func_iconv_works = "yes";
      });
      libidn2 = super.libidn2.overrideAttrs (attrs: {
        postFixup = attrs.postFixup or "" + ''
          ${self.nukeReferences}/bin/nuke-refs -e '${lib.getLib self.libunistring}' \
            "$out"/lib/lib*.so.*.*
        '';
      });

      # This also contains the full, dynamically linked, final Glibc.
      binutils = prevStage.binutils.override {
        # Rewrap the binutils with the new glibc, so both the next
        # stage's wrappers use it.
        libc = getLibc self;

        # Unfortunately, when building gcc in the next stage, its LTO plugin
        # would use the final libc but `ld` would use the bootstrap one,
        # and that can fail to load.  Therefore we upgrade `ld` to use newer libc;
        # apparently the interpreter needs to match libc, too.
        bintools = self.stdenvNoCC.mkDerivation {
          inherit (prevStage.bintools.bintools) name;
          enableParallelBuilding = true;
          dontUnpack = true;
          dontBuild = true;
          strictDeps = true;
          # We wouldn't need to *copy* all, but it's easier and the result is temporary anyway.
          installPhase = ''
            mkdir -p "$out"/bin
            cp -a '${prevStage.bintools.bintools}'/bin/* "$out"/bin/
            chmod +w "$out"/bin/ld.bfd
            patchelf --set-interpreter '${getLibc self}'/lib/ld*.so.? \
              --set-rpath "${getLibc self}/lib:$(patchelf --print-rpath "$out"/bin/ld.bfd)" \
              "$out"/bin/ld.bfd
          '';
        };
      };
    };

    # `libtool` comes with obsolete config.sub/config.guess that don't recognize Risc-V.
    extraNativeBuildInputs =
      lib.optional (localSystem.isRiscV) prevStage.updateAutotoolsGnuConfigScriptsHook;
  })


  # Construct a third stdenv identical to the 2nd, except that this
  # one uses the rebuilt Glibc from stage2.  It still uses the recent
  # binutils and rest of the bootstrap tools, including GCC.
  #
  # resulting stage3 stdenv:
  # - coreutils, gcc: from bootstrapFiles
  # - glibc, binutils: from nixpkgs, built by bootstrapFiles toolchain
  (prevStage: stageFun prevStage {
    name = "bootstrap-stage3";

    overrides = self: super: rec {
      inherit (prevStage)
        ccWrapperStdenv
        binutils coreutils gnugrep
        perl patchelf linuxHeaders gnum4 bison libidn2 libunistring;
      ${localSystem.libc} = getLibc prevStage;
      gcc-unwrapped =
        let makeStaticLibrariesAndMark = pkg:
              lib.makeOverridable (pkg.override { stdenv = self.makeStaticLibraries self.stdenv; })
                .overrideAttrs (a: { pname = "${a.pname}-stage3"; });
        in super.gcc-unwrapped.override {
        # Link GCC statically against GMP etc.  This makes sense because
        # these builds of the libraries are only used by GCC, so it
        # reduces the size of the stdenv closure.
        gmp = makeStaticLibrariesAndMark super.gmp;
        mpfr = makeStaticLibrariesAndMark super.mpfr;
        libmpc = makeStaticLibrariesAndMark super.libmpc;
        isl = makeStaticLibrariesAndMark super.isl_0_20;
        # Use a deterministically built compiler
        # see https://github.com/NixOS/nixpkgs/issues/108475 for context
        reproducibleBuild = true;
        profiledCompiler = false;
      };
    };
    extraNativeBuildInputs = [ prevStage.patchelf ] ++
      # Many tarballs come with obsolete config.sub/config.guess that don't recognize aarch64.
      lib.optional (!localSystem.isx86 || localSystem.libc == "musl")
                   prevStage.updateAutotoolsGnuConfigScriptsHook;
  })


  # Construct a fourth stdenv that uses the new GCC.  But coreutils is
  # still from the bootstrap tools.
  #
  # resulting stage4 stdenv:
  # - coreutils: from bootstrapFiles
  # - glibc, binutils: from nixpkgs, built by bootstrapFiles toolchain
  # - gcc: from nixpkgs, built by bootstrapFiles toolchain. Can assume
  #        it has almost no code from bootstrapTools as gcc bootstraps
  #        internally. The only exceptions are crt files from glibc
  #        built by bootstrapTools used to link executables and libraries,
  #        and the bootstrapTools-built, statically-linked
  #        lib{mpfr,mpc,gmp,isl}.a which are linked into the final gcc
  #        (see commit cfde88976ba4cddd01b1bb28b40afd12ea93a11d).
  (prevStage: stageFun prevStage {
    name = "bootstrap-stage4";

    overrides = self: super: {
      # Zlib has to be inherited and not rebuilt in this stage,
      # because gcc (since JAR support) already depends on zlib, and
      # then if we already have a zlib we want to use that for the
      # other purposes (binutils and top-level pkgs) too.
      inherit (prevStage) gettext gnum4 bison perl texinfo zlib linuxHeaders libidn2 libunistring;
      ${localSystem.libc} = getLibc prevStage;
      binutils = super.binutils.override {
        # Don't use stdenv's shell but our own
        shell = self.bash + "/bin/bash";
        # Build expand-response-params with last stage like below
        buildPackages = {
          inherit (prevStage) stdenv;
        };
      };

      # force gmp to rebuild so we have the option of dynamically linking
      # libgmp without creating a reference path from:
      #   stage5.gcc -> stage4.coreutils -> stage3.glibc -> bootstrap
      gmp = lib.makeOverridable (super.gmp.override { stdenv = self.stdenv; }).overrideAttrs (a: { pname = "${a.pname}-stage4"; });

      # To allow users' overrides inhibit dependencies too heavy for
      # bootstrap, like guile: https://github.com/NixOS/nixpkgs/issues/181188
      gnumake = super.gnumake.override { inBootstrap = true; };

      gcc = lib.makeOverridable (import ../../build-support/cc-wrapper) {
        nativeTools = false;
        nativeLibc = false;
        isGNU = true;
        buildPackages = {
          inherit (prevStage) stdenv;
        };
        cc = prevStage.gcc-unwrapped;
        bintools = self.binutils;
        libc = getLibc self;
        inherit lib;
        inherit (self) stdenvNoCC coreutils gnugrep;
        shell = self.bash + "/bin/bash";
      };
    };
    extraNativeBuildInputs = [ prevStage.patchelf prevStage.xz ] ++
      # Many tarballs come with obsolete config.sub/config.guess that don't recognize aarch64.
      lib.optional (!localSystem.isx86 || localSystem.libc == "musl")
                   prevStage.updateAutotoolsGnuConfigScriptsHook;
  })

  # Construct the final stdenv.  It uses the Glibc and GCC, and adds
  # in a new binutils that doesn't depend on bootstrap-tools, as well
  # as dynamically linked versions of all other tools.
  #
  # When updating stdenvLinux, make sure that the result has no
  # dependency (`nix-store -qR') on bootstrapTools or the first
  # binutils built.
  #
  # resulting stage5 (final) stdenv:
  # - coreutils, binutils: from nixpkgs, built by nixpkgs toolchain
  # - glibc: from nixpkgs, built by bootstrapFiles toolchain
  # - gcc: from nixpkgs, built by bootstrapFiles toolchain. Can assume
  #        it has almost no code from bootstrapTools as gcc bootstraps
  #        internally. The only exceptions are crt files from glibc
  #        built by bootstrapTools used to link executables and libraries,
  #        and the bootstrapTools-built, statically-linked
  #        lib{mpfr,mpc,gmp,isl}.a which are linked into the final gcc
  #        (see commit cfde88976ba4cddd01b1bb28b40afd12ea93a11d).
  (prevStage: {
    inherit config overlays;
    stdenv = import ../generic rec {
      name = "stdenv-linux";

      buildPlatform = localSystem;
      hostPlatform = localSystem;
      targetPlatform = localSystem;
      inherit config;

      preHook = commonPreHook;

      initialPath =
        ((import ../generic/common-path.nix) {pkgs = prevStage;});

      extraNativeBuildInputs = [ prevStage.patchelf ] ++
        # Many tarballs come with obsolete config.sub/config.guess that don't recognize aarch64.
        lib.optional (!localSystem.isx86 || localSystem.libc == "musl")
        prevStage.updateAutotoolsGnuConfigScriptsHook;

      cc = prevStage.gcc;

      shell = cc.shell;

      inherit (prevStage.stdenv) fetchurlBoot;

      extraAttrs = {
        inherit bootstrapTools;
        shellPackage = prevStage.bash;
      };

      disallowedRequisites = [ bootstrapTools.out ];

      # Mainly avoid reference to bootstrap tools
      allowedRequisites = with prevStage; with lib;
        # Simple executable tools
        concatMap (p: [ (getBin p) (getLib p) ]) [
            gzip bzip2 xz bash binutils.bintools coreutils diffutils findutils
            gawk gmp gnumake gnused gnutar gnugrep gnupatch patchelf ed file
          ]
        # Library dependencies
        ++ map getLib (
            [ attr acl zlib pcre libidn2 libunistring ]
            ++ lib.optional (gawk.libsigsegv != null) gawk.libsigsegv
          )
        # More complicated cases
        ++ (map (x: getOutput x (getLibc prevStage)) [ "out" "dev" "bin" ] )
        ++  [ /*propagated from .dev*/ linuxHeaders
            binutils gcc gcc.cc gcc.cc.lib gcc.expand-response-params
          ]
          ++ lib.optionals (!localSystem.isx86 || localSystem.libc == "musl")
            [ prevStage.updateAutotoolsGnuConfigScriptsHook prevStage.gnu-config ];

      overrides = self: super: {
        inherit (prevStage)
          gzip bzip2 xz bash coreutils diffutils findutils gawk
          gnused gnutar gnugrep gnupatch patchelf
          attr acl zlib pcre libunistring;
        ${localSystem.libc} = getLibc prevStage;

        # Hack: avoid libidn2.{bin,dev} referencing bootstrap tools.  There's a logical cycle.
        libidn2 = import ../../development/libraries/libidn2/no-bootstrap-reference.nix {
          inherit lib;
          inherit (prevStage) libidn2;
          inherit (self) stdenv runCommandLocal patchelf libunistring;
        };

        gnumake = super.gnumake.override { inBootstrap = false; };
      } // lib.optionalAttrs (super.stdenv.targetPlatform == localSystem) {
        # Need to get rid of these when cross-compiling.
        inherit (prevStage) binutils binutils-unwrapped;
        gcc = cc;
      };
    };
  })

]
