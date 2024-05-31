{ lib
, pkgsBuildBuild
, vendorCargoRegistries
, vendorGitDeps
}:

let
  inherit (pkgsBuildBuild)
    runCommandLocal;

  inherit (builtins)
    attrNames
    attrValues
    fromTOML
    readFile;

  inherit (lib)
    concatMapStrings
    escapeShellArg
    groupBy;

  inherit (lib.attrsets)
    filterAttrs
    optionalAttrs;

  inherit (lib.lists)
    flatten
    unique;

  # Define or adjust vendorCargoRegistries to ensure no filtering
  vendorCargoRegistries = { cargoConfigs, lockPackages, overrideVendorCargoPackage, registries ? null }:
    let
      includeAllFiles = path: type: true; # Accept all files

      generateRegistryConfig = registries: ''
        [source.crates-io]
        replace-with = "vendored-sources"

        [source.vendored-sources]
        directory = "${registries}"
      '';
    in
    {
      config = generateRegistryConfig ./vendor; # Assuming `./vendor` is the vendored directory
      sources = lib.cleanSourceWith {
        src = ./.; # Path to your source directory
        filter = includeAllFiles;
      };
    };

  # Define or adjust vendorGitDeps to ensure no filtering
  vendorGitDeps = { lockPackages, outputHashes, overrideVendorGitCheckout }:
    let
      includeAllFiles = path: type: true; # Accept all files

      generateGitConfig = gitDeps: concatMapStrings (dep: ''
        [source.${dep.id}]
        replace-with = "vendored-sources-${dep.id}"

        [source.vendored-sources-${dep.id}]
        directory = "${dep.path}"
      '') gitDeps;
    in
    {
      config = generateGitConfig (map (dep: {
        id = dep.name;
        path = ./vendor/${dep.name};
      }) lockPackages); # Adjust paths as needed
      sources = lib.cleanSourceWith {
        src = ./.; # Path to your source directory
        filter = includeAllFiles;
      };
    };

in
{ cargoConfigs ? [ ]
, cargoLockContentsList ? [ ]
, cargoLockList ? [ ]
, cargoLockParsedList ? [ ]
, outputHashes ? { }
, overrideVendorCargoPackage ? _: drv: drv
, overrideVendorGitCheckout ? _: drv: drv
, registries ? null
}:

let
  cargoLocksParsed = (map fromTOML ((map readFile cargoLockList) ++ cargoLockContentsList))
    ++ cargoLockParsedList;

  allowedAttrs = {
    name = true;
    version = true;
    source = true;
    checksum = true;
  };

  allPackagesTrimmed = map
    (l: map
      (filterAttrs (k: _: allowedAttrs.${k} or false))
      ((l.package or [ ]) ++ (l.patch.unused or [ ]))
    )
    cargoLocksParsed;

  lockPackages = flatten (map unique (attrValues (groupBy
    (p: "${p.name}:${p.version}:${p.source or "local-path"}")
    (flatten allPackagesTrimmed)
  )));

  vendoredRegistries = vendorCargoRegistries ({
    inherit cargoConfigs lockPackages overrideVendorCargoPackage;
  } // optionalAttrs (registries != null) { inherit registries; });

  vendoredGit = vendorGitDeps {
    inherit lockPackages outputHashes overrideVendorGitCheckout;
  };

  linkSources = sources: concatMapStrings
    (name: ''
      ln -s ${escapeShellArg sources.${name}} $out/${escapeShellArg name}
    '')
    (attrNames sources);

in
runCommandLocal "vendor-cargo-deps" { } ''
  mkdir -p $out
  cat >>$out/config.toml <<EOF
  ${vendoredRegistries.config}
  ${vendoredGit.config}
  EOF

  ${linkSources vendoredRegistries.sources}
  ${linkSources vendoredGit.sources}
''
