# # Nvidia informations.
{
  # Version of the system kernel module. Let it to null to enable auto-detection.
  nvidiaVersion ? null,
  # Hash of the Nvidia driver .run file. null is fine, but fixing a value here
  # will be more reproducible and more efficient.
  nvidiaHash ? null,
  # Alternatively, you can pass a path that points to a nvidia version file
  # and let nixGL extract the version from it. That file must be a copy of
  # /proc/driver/nvidia/version. Nix doesn't like zero-sized files (see
  # https://github.com/NixOS/nix/issues/3539 ).
  nvidiaVersionFile ? null,
  # Enable 32 bits driver
  # This is one by default, you can switch it to off if you want to reduce a
  # bit the size of nixGL closure.
  enable32bits ? stdenv.hostPlatform.isx86,
  bumblebee,
  driversi686Linux,
  fetchurl,
  gcc,
  intel-media-driver,
  lib,
  libdrm,
  libglvnd,
  libvdpau-va-gl,
  linuxPackages,
  mesa,
  pcre,
  pkgsi686Linux,
  runCommand,
  shellcheck,
  stdenv,
  substitute,
  vulkan-validation-layers,
  wayland,
  writeShellApplication,
  xorg,
  zlib,
  zstd,
}:

let
  inherit (lib.lists) optionals;
  inherit (lib.meta) getExe';
  inherit (lib.strings) concatMapStringsSep makeLibraryPath makeSearchPathOutput optionalString;

  writeExecutable =
    {
      name,
      envSetupText,
      epilogueText,
    }:
    writeShellApplication {
      inherit name;

      text = ''
        ${envSetupText}
        ${epilogueText}
      '';

      # Check that all the files listed in the output binary exists
      derivationArgs = {
        passthru = {
          inherit envSetupText epilogueText;
        };
        postCheck = ''
          for i in $(${getExe' pcre "pcre"}  -o0 '/nix/store/.*?/[^ ":]+' $out/bin/${name})
          do
            ls $i > /dev/null || (echo "File $i, referenced in $out/bin/${name} does not exists."; exit -1)
          done
        '';
      };
    };

  writeNixGL =
    name: vadrivers:
    writeExecutable {
      inherit name;

      envSetupText =
        let
          mesa-drivers = [ mesa.drivers ] ++ optionals enable32bits [ pkgsi686Linux.mesa.drivers ];
          libvdpau = [ libvdpau-va-gl ] ++ optionals enable32bits [ pkgsi686Linux.libvdpau-va-gl ];
          libglvnds = [ libglvnd ] ++ optionals enable32bits [ pkgsi686Linux.libglvnd ];
          glxindirect = runCommand "mesa_glxindirect" { } ''
            mkdir -p $out/lib
            ln -s ${mesa.drivers}/lib/libGLX_mesa.so.0 $out/lib/libGLX_indirect.so.0
          '';
        in
        ''
          export LIBGL_DRIVERS_PATH=${makeSearchPathOutput "lib" "lib/dri" mesa-drivers}
          export LIBVA_DRIVERS_PATH=${makeSearchPathOutput "out" "lib/dri" (mesa-drivers ++ vadrivers)}
          export __EGL_VENDOR_LIBRARY_FILENAMES=${
            concatMapStringsSep ":" (drivers: drivers + "/share/glvnd/egl_vendor.d/50_mesa.json") mesa-drivers
          }"''${__EGL_VENDOR_LIBRARY_FILENAMES:+:$__EGL_VENDOR_LIBRARY_FILENAMES}"
          export LD_LIBRARY_PATH=${
            makeLibraryPath (
              mesa-drivers
              ++ [
                (makeSearchPathOutput "lib" "lib/vdpau" libvdpau)
                "${glxindirect}/lib"
              ]
              ++ libglvnds
            )
          }"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      epilogueText = ''
        exec "$@"
      '';
    };
  top = rec {
    /*
      It contains the builder for different nvidia configuration, parametrized by
      the version of the driver and sha256 sum of the driver installer file.
    */
    nvidiaPackages =
      {
        version,
        sha256 ? null,
      }:
      let
        nvidiaDrivers = linuxPackages.nvidia_x11.overrideAttrs (prevAttrs: {
          pname = "nvidia";
          name = "nvidia-x11-${version}-nixGL";
          inherit version;
          src =
            let
              url = "https://download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run";
            in
            if sha256 != null then fetchurl { inherit url sha256; } else builtins.fetchurl url;
          useGLVND = true;
          nativeBuildInputs = prevAttrs.nativeBuildInputs or [ ] ++ [ zstd ];
        });

        nvidiaLibsOnly = nvidiaDrivers.override {
          libsOnly = true;
          kernel = null;
        };

        # TODO: 32bit version? Not tested.
        nixNvidiaWrapper =
          api:
          writeExecutable {
            name = "nix${api}Nvidia-${version}";
            envSetupText =
              let
                isVulkan = api == "Vulkan";
                nvidia-libs = [nvidiaLibsOnly] ++ optionals enable32bits [ nvidiaLibsOnly.lib32 ];
                libglvnds = [ libglvnd ] ++ optionals enable32bits [ pkgsi686Linux.libglvnd ];
              in
              # General setup
              ''
                export __EGL_VENDOR_LIBRARY_FILENAMES=${
                  concatMapStringsSep ":" (libs: libs + "/share/glvnd/egl_vendor.d/10_nvidia.json") nvidia-libs
                }"''${__EGL_VENDOR_LIBRARY_FILENAMES:+:$__EGL_VENDOR_LIBRARY_FILENAMES}"
              ''
              # Vulkan-specific variables
              + optionalString isVulkan ''
                export VK_LAYER_PATH=${vulkan-validation-layers}/share/vulkan/explicit_layer.d
                export VK_ICD_FILENAMES=${
                  concatMapStringsSep ":" (libs: libs + "/share/vulkan/icd.d/nvidia_icd.x86_64.json") nvidia-libs
                }"''${VK_ICD_FILENAMES:+:$VK_ICD_FILENAMES}"
              ''
              # Update LD_LIBRARY_PATH
              + ''
                export LD_LIBRARY_PATH=${
                  makeLibraryPath (nvidia-libs ++ libglvnds ++ optionals isVulkan [ vulkan-validation-layers ])
                }"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              '';
            epilogueText = ''
              exec "$@"
            '';
          };
      in
      {
        inherit nvidiaDrivers nvidiaLibsOnly nixNvidiaWrapper;

        nixGLNvidiaBumblebee =
          let
            bumblebee' = bumblebee.override {
              nvidia_x11 = nvidiaDrivers;
              nvidia_x11_i686 = nvidiaDrivers.lib32;
            };
            extraPaths = makeLibraryPath (
              [ nvidiaDrivers ]
              ++ optionals enable32bits [ nvidiaDrivers.lib32 ]
              ++ [ libglvnd ]
              ++ optionals enable32bits [ pkgsi686Linux.libglvnd ]
            );
          in
          writeExecutable {
            name = "nixGLNvidiaBumblebee-${version}";
            envSetupText = ''
              export LD_LIBRARY_PATH=${extraPaths}"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
            epilogueText = ''
              ${getExe' bumblebee' "optirun"} --ldpath ${extraPaths} "$@"
            '';
          };

        # TODO: 32bit version? Not tested.
        nixGLNvidia = nixNvidiaWrapper "GL";

        # TODO: 32bit version? Not tested.
        nixVulkanNvidia = nixNvidiaWrapper "Vulkan";
      };

    nixGLMesa = writeNixGL "nixGLMesa" [ ];

    nixGLIntel = writeNixGL "nixGLIntel" (
      [ intel-media-driver ] ++ optionals enable32bits [ pkgsi686Linux.intel-media-driver ]
    );

    nixVulkanMesa = writeExecutable {
      name = "nixVulkanIntel";
      text =
        let
          # generate a file with the listing of all the icd files
          icd = runCommand "mesa_icd" { } (
            # 64 bits icd
            ''
              ls ${mesa.drivers}/share/vulkan/icd.d/*.json > f
            ''
            #  32 bits ones
            + optionalString enable32bits ''
              ls ${pkgsi686Linux.mesa.drivers}/share/vulkan/icd.d/*.json >> f
            ''
            # concat everything as a one line string with ":" as seperator
            + ''cat f | xargs | sed "s/ /:/g" > $out''
          );
        in
        ''
          if [ -n "$LD_LIBRARY_PATH" ]; then
            echo "Warning, nixVulkanIntel overwriting existing LD_LIBRARY_PATH" 1>&2
          fi
          export VK_LAYER_PATH=${vulkan-validation-layers}/share/vulkan/explicit_layer.d
          ICDS=$(cat ${icd})
          export VK_ICD_FILENAMES=$ICDS"''${VK_ICD_FILENAMES:+:$VK_ICD_FILENAMES}"
          export LD_LIBRARY_PATH=${
            makeLibraryPath [
              zlib
              libdrm
              xorg.libX11
              xorg.libxcb
              xorg.libxshmfence
              wayland
              gcc.cc
            ]
          }"''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          exec "$@"
        '';
    };

    nixVulkanIntel = nixVulkanMesa;

    nixGLCommon =
      nixGL:
      runCommand "nixGL" { } ''
        mkdir -p "$out/bin"
        # star because nixGLNvidia... have version prefixed name
        cp ${nixGL}/bin/* "$out/bin/nixGL";
      '';

    auto =
      let
        _nvidiaVersionFile =
          if nvidiaVersionFile != null then
            nvidiaVersionFile
          else
            # HACK: Get the version from /proc. It turns out that /proc is mounted
            # inside of the build sandbox and varies from machine to machine.
            #
            # builtins.readFile is not able to read /proc files. See
            # https://github.com/NixOS/nix/issues/3539.
            runCommand "impure-nvidia-version-file" {
              # To avoid sharing the build result over time or between machine,
              # Add an impure parameter to force the rebuild on each access.
              time = builtins.currentTime;
              preferLocalBuild = true;
              allowSubstitutes = false;
            } "cp /proc/driver/nvidia/version $out 2> /dev/null || touch $out";

        # The nvidia version. Either fixed by the `nvidiaVersion` argument, or
        # auto-detected. Auto-detection is impure.
        nvidiaVersionAuto =
          if nvidiaVersion != null then
            nvidiaVersion
          else
            # Get if from the nvidiaVersionFile
            let
              data = builtins.readFile _nvidiaVersionFile;
              versionMatch = builtins.match ".*Module  ([0-9.]+)  .*" data;
            in
            if versionMatch != null then builtins.head versionMatch else null;

        autoNvidia = nvidiaPackages { version = nvidiaVersionAuto; };
      in
      {
        # The output derivation contains nixGL which point either to
        # nixGLNvidia or nixGLIntel using an heuristic.
        nixGLDefault =
          if nvidiaVersionAuto != null then nixGLCommon autoNvidia.nixGLNvidia else nixGLCommon nixGLIntel;
      }
      // autoNvidia;
  };
in
top
// (
  if nvidiaVersion != null then
    top.nvidiaPackages {
      version = nvidiaVersion;
      sha256 = nvidiaHash;
    }
  else
    { }
)
