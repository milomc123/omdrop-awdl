{ lib }:
let
  patchDir = ../patches;
  names = builtins.filter (name: lib.hasSuffix ".patch" name) (
    builtins.attrNames (builtins.readDir patchDir)
  );
in
map (name: patchDir + "/${name}") names
