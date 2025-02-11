{ self, pkgs, system, lib, root, ... }:

let
  inherit (builtins) attrNames readDir mapAttrs;
  inherit (lib)
    flip pipe mkForce filterAttrs flatten listToAttrs forEach nameValuePair
    mapAttrs';

  readDirRec = path:
    pipe path [
      readDir
      (filterAttrs (n: v: v == "directory" || n == "default.nix"))
      attrNames
      (map (name: path + "/${name}"))
      (map (child:
        if (baseNameOf child) == "default.nix" then
          child
        else
          readDirRec child))
      flatten
    ];

  mkSystem = nodeName: modules:
    self.inputs.nixpkgs.lib.nixosSystem {
      inherit pkgs system;
      modules = [
        self.inputs.bitte.nixosModule
        (self.inputs.nixpkgs + "/nixos/modules/virtualisation/amazon-image.nix")
      ] ++ modules;
      specialArgs = { inherit nodeName self; };
    };

  clusterFiles = readDirRec root;

in listToAttrs (forEach clusterFiles (file:
  let
    proto = self.inputs.nixpkgs.lib.nixosSystem {
      inherit pkgs system;
      modules = [
        self.inputs.bitte.nixosModule
        ../profiles/nix.nix
        ../profiles/consul/policies.nix
        file
      ];
      specialArgs = { inherit self; };
    };

    tf = proto.config.tf;

    nodes = mapAttrs (name: instance:
      mkSystem name
      ([ { networking.hostName = mkForce name; } file ] ++ instance.modules))
      proto.config.cluster.instances;

    groups =
      mapAttrs (name: instance: mkSystem name ([ file ] ++ instance.modules))
      proto.config.cluster.autoscalingGroups;

    # All data used by the CLI should be exported here.
    topology = {
      nodes = flip mapAttrs proto.config.cluster.instances (name: node: {
        inherit (proto.config.cluster) kms region;
        inherit (node) name privateIP instanceType;
      });
      groups = attrNames groups;
    };

    secrets = pkgs.callPackages ../pkgs/bitte-secrets.nix {
      inherit (proto.config) cluster;
    };

    mkJob = import ./mk-job.nix proto;

  in nameValuePair proto.config.cluster.name {
    inherit proto tf nodes groups topology secrets mkJob;
  }))
