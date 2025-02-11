{ self, config, pkgs, nodeName, ... }:
let
  inherit (pkgs) lib terralib;
  inherit (lib) mkOption reverseList;
  inherit (lib.types)
    attrs submodule str attrsOf bool ints path enum port listof nullOr listOf
    oneOf list package unspecified anything;
  inherit (terralib) var id regions awsProviderFor;

  kms2region = kms: builtins.elemAt (lib.splitString ":" kms) 3;

  merge = lib.foldl' lib.recursiveUpdate { };

  amis = let
    nixosAmis = import
      (self.inputs.nixpkgs + "/nixos/modules/virtualisation/ec2-amis.nix");
  in {
    nixos = lib.mapAttrs' (name: value: lib.nameValuePair name value.hvm-ebs)
      nixosAmis."20.03";
  };

  autoscalingAMIs = {
    us-east-2 = "ami-0492aa69cf46f79c3";
    eu-central-1 = "ami-0839f2c610f876d2d";
    eu-west-1 = "ami-0f765805e4520b54d";
    us-east-1 = "ami-02700dd542e3304cd";
  };

  vpcMap = lib.pipe [
    "ap-northeast-1"
    "ap-northeast-2"
    "ap-south-1"
    "ap-southeast-1"
    "ap-southeast-2"
    "ca-central-1"
    "eu-central-1"
    "eu-north-1"
    "eu-west-1"
    "eu-west-2"
    "eu-west-3"
    "sa-east-1"
    "us-east-1"
    "us-east-2"
    "us-west-1"
    "us-west-2"
  ] [ (lib.imap0 (i: v: lib.nameValuePair v i)) builtins.listToAttrs ];

  cfg = config.cluster;

  clusterType = submodule ({ ... }: {
    options = {
      name = mkOption { type = str; };

      domain = mkOption { type = str; };

      secrets = mkOption { type = path; };

      terraformOrganization = mkOption { type = str; };

      instances = mkOption {
        type = attrsOf serverType;
        default = { };
      };

      autoscalingGroups = mkOption {
        type = attrsOf autoscalingGroupType;
        default = { };
      };

      route53 = mkOption {
        type = bool;
        default = true;
        description = "Enable route53 registrations";
      };

      ami = mkOption {
        type = str;
        default = amis.nixos.${cfg.region};
      };

      iam = mkOption {
        type = clusterIamType;
        default = { };
      };

      kms = mkOption { type = str; };

      s3Bucket = mkOption { type = str; };

      s3Cache = mkOption {
        type = str;
        default =
          "s3://${cfg.s3Bucket}/infra/binary-cache/?region=${cfg.region}";
      };

      s3CachePubKey = mkOption { type = str; };

      adminNames = mkOption {
        type = listOf str;
        default = [ ];
      };

      adminGithubTeamNames = mkOption {
        type = listOf str;
        default = [ "devops" ];
      };

      developerGithubTeamNames = mkOption {
        type = listOf str;
        default = [ ];
      };

      developerGithubNames = mkOption {
        type = listOf str;
        default = [ ];
      };

      extraAcmeSANs = mkOption {
        type = listOf str;
        default = [ ];
        description = ''
          Extra subject alternative names to add to the default certs for the cluster.

          NOTE: Use of this option requires a recent version of an ACME terraform
          provider, such as one of:

          https://github.com/getstackhead/terraform-provider-acme/releases/tag/v1.5.0-patched2
          https://github.com/vancluever/terraform-provider-acme/releases/tag/v2.4.0

          Specifically, the ACME provider version must be patched for this issue:

          https://github.com/vancluever/terraform-provider-acme/issues/154
        '';
      };

      generateSSHKey = mkOption {
        type = bool;
        default = true;
      };

      region = mkOption {
        type = str;
        default = kms2region cfg.kms;
      };

      vpc = mkOption {
        type = vpcType cfg.name;
        default = {
          region = cfg.region;

          cidr = "172.16.0.0/16";

          subnets = {
            core-1.cidr = "172.16.0.0/24";
            core-2.cidr = "172.16.1.0/24";
            core-3.cidr = "172.16.2.0/24";
          };
        };
      };

      certificate = mkOption {
        type = certificateType;
        default = { };
      };

      flakePath = mkOption {
        type = path;
        default = self.outPath;
      };
    };
  });

  clusterIamType = submodule {
    options = {
      roles = mkOption {
        type = attrsOf iamRoleType;
        default = { };
      };
    };
  };

  iamRoleType = submodule ({ name, ... }@this: {
    options = {
      id = mkOption {
        type = str;
        default = id "aws_iam_role.${this.config.uid}";
      };

      uid = mkOption {
        type = str;
        default = "${cfg.name}-${this.config.name}";
      };

      name = mkOption {
        type = str;
        default = name;
      };

      tfName = mkOption {
        type = str;
        default = var "aws_iam_role.${this.config.uid}.name";
      };

      tfDataName = mkOption {
        type = str;
        default = var "data.aws_iam_role.${this.config.uid}.name";
      };

      assumePolicy = mkOption {
        type = iamRoleAssumePolicyType;
        default = { };
      };

      policies = mkOption {
        type = attrsOf (iamRolePolicyType this.config.uid);
        default = { };
      };
    };
  });

  iamRolePolicyType = parentUid:
    (submodule ({ name, ... }@this: {
      options = {
        uid = mkOption {
          type = str;
          default = "${parentUid}-${this.config.name}";
        };

        name = mkOption {
          type = str;
          default = name;
        };

        effect = mkOption {
          type = enum [ "Allow" "Deny" ];
          default = "Allow";
        };

        actions = mkOption { type = listOf str; };

        resources = mkOption { type = listOf str; };

        condition = mkOption {
          type = nullOr (listOf attrs);
          default = null;
        };
      };
    }));

  iamRoleAssumePolicyType = submodule ({ ... }@this: {
    options = {
      tfJson = mkOption {
        type = str;
        apply = _:
          builtins.toJSON {
            Version = "2012-10-17";
            Statement = [{
              Effect = this.config.effect;
              Principal.Service = this.config.principal.service;
              Action = this.config.action;
              Sid = "";
            }];
          };
      };

      effect = mkOption {
        type = enum [ "Allow" "Deny" ];
        default = "Allow";
      };

      action = mkOption { type = str; };

      principal = mkOption { type = iamRolePrincipalsType; };
    };
  });

  iamRolePrincipalsType =
    submodule { options = { service = mkOption { type = str; }; }; };

  initialVaultSecretsType = submodule ({ ... }@this: {
    options = {
      consul = mkOption {
        type = str;
        default = builtins.trace "initialVaultSecrets is not used anymore!" "";
      };
      nomad = mkOption {
        type = str;
        default = builtins.trace "initialVaultSecrets is not used anymore!" "";
      };
    };
  });

  certificateType = submodule ({ ... }@this: {
    options = {
      organization = mkOption {
        type = str;
        default = "IOHK";
      };

      commonName = mkOption {
        type = str;
        default = this.config.organization;
      };

      validityPeriodHours = mkOption {
        type = ints.positive;
        default = 8760;
      };
    };
  });

  securityGroupRuleType = { defaultSecurityGroupId }:
    submodule ({ name, ... }@this: {
      options = {
        name = mkOption {
          type = str;
          default = name;
        };

        type = mkOption {
          type = enum [ "ingress" "egress" ];
          default = "ingress";
        };

        port = mkOption {
          type = nullOr port;
          default = null;
        };

        from = mkOption {
          type = port;
          default = this.config.port;
        };

        to = mkOption {
          type = port;
          default = this.config.port;
        };

        protocols = mkOption {
          type = listOf (enum [ "tcp" "udp" "-1" ]);
          default = [ "tcp" ];
        };

        cidrs = mkOption {
          type = listOf str;
          default = [ ];
        };

        securityGroupId = mkOption {
          type = str;
          default = defaultSecurityGroupId;
        };

        self = mkOption {
          type = bool;
          default = false;
        };

        sourceSecurityGroupId = mkOption {
          type = nullOr str;
          default = null;
        };
      };
    });

  vpcType = prefix:
    (submodule ({ ... }@this: {
      options = {
        name = mkOption {
          type = str;
          default = "${prefix}-${this.config.region}";
        };

        cidr = mkOption { type = str; };

        id = mkOption {
          type = str;
          default = id "data.aws_vpc.${this.config.name}";
        };

        region = mkOption { type = enum regions; };

        subnets = mkOption {
          type = attrsOf subnetType;
          default = { };
        };
      };
    }));

  subnetType = submodule ({ name, ... }@this: {
    options = {
      name = mkOption {
        type = str;
        default = name;
      };

      cidr = mkOption { type = str; };

      id = mkOption {
        type = str;
        default = id "aws_subnet.${this.config.name}";
      };
    };
  });

  serverIamType = parentName:
    submodule {
      options = {
        role = mkOption { type = iamRoleType; };

        instanceProfile = mkOption { type = instanceProfileType parentName; };
      };
    };

  instanceProfileType = parentName:
    submodule {
      options = {
        tfName = mkOption {
          type = str;
          readOnly = true;
          default =
            var "aws_iam_instance_profile.${cfg.name}-${parentName}.name";
        };

        tfArn = mkOption {
          type = str;
          readOnly = true;
          default =
            var "aws_iam_instance_profile.${cfg.name}-${parentName}.arn";
        };

        role = mkOption { type = iamRoleType; };

        path = mkOption {
          type = str;
          default = "/";
        };
      };
    };

  serverType = submodule ({ name, ... }@this: {
    options = {
      name = mkOption {
        type = str;
        default = name;
      };

      uid = mkOption {
        type = str;
        default = "${cfg.name}-${name}";
      };

      enable = mkOption {
        type = bool;
        default = true;
      };

      domain = mkOption {
        type = str;
        default = "${this.config.name}.${cfg.domain}";
      };

      modules = mkOption {
        type = listOf anything;
        default = [ ];
      };

      ami = mkOption {
        type = str;
        default = config.cluster.ami;
      };

      iam = mkOption {
        type = serverIamType this.config.name;
        default = {
          role = cfg.iam.roles.core;
          instanceProfile.role = cfg.iam.roles.core;
        };
      };

      route53 = mkOption {
        default = { domains = [ ]; };
        type = submodule {
          options = {
            domains = mkOption {
              type = listOf str;
              default = [ ];
            };
          };
        };
      };

      userData = mkOption {
        type = nullOr str;
        default = ''
          ### https://nixos.org/channels/nixpkgs-unstable nixos
          { pkgs, config, ... }: {
            imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];

            nix = {
              package = pkgs.nixFlakes;
              extraOptions = '''
                show-trace = true
                experimental-features = nix-command flakes ca-references
              ''';
              binaryCaches = [
                "https://hydra.iohk.io"
                "${cfg.s3Cache}"
              ];
              binaryCachePublicKeys = [
                "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
                "${cfg.s3CachePubKey}"
              ];
            };

            environment.etc.ready.text = "true";
          }
        '';
      };

      # Gotta do it this way since TF outputs aren't generated at this point and we need the IP.
      localProvisioner = mkOption {
        type = localExecType;
        default = let
          ip = var "aws_eip.${this.config.uid}.public_ip";
          args = [
            "${pkgs.bitte}/bin/bitte"
            "provision"
            ip
            this.config.name # name
            cfg.name # cluster name
            "." # flake path
            "${cfg.name}-${this.config.name}" # flake attr
            cfg.s3Cache
          ];
          rev = reverseList args;
          command = builtins.head rev;
          interpreter = reverseList (builtins.tail rev);
        in { inherit command interpreter; };
      };

      postDeploy = mkOption {
        type = localExecType;
        default = {
          # command = name;
          # interpreter = let
          #   ip = var "aws_eip.${this.config.uid}.public_ip";
          # in [
          #   "${pkgs.bitte}/bin/bitte"
          #   "deploy"
          #   "--cluster"
          #   "${cfg.name}"
          #   "--ip"
          #   "${ip}"
          #   "--flake"
          #   "${this.config.flake}"
          #   "--flake-host"
          #   "${name}"
          #   "--name"
          #   "${this.config.uid}"
          # ];
        };
      };

      instanceType = mkOption { type = str; };

      tags = mkOption {
        type = attrsOf str;
        default = {
          Cluster = cfg.name;
          Name = this.config.name;
          UID = this.config.uid;
          Consul = "server";
          Vault = "server";
          Nomad = "server";
        };
      };

      privateIP = mkOption { type = str; };

      # flake = mkOption { type = str; };

      subnet = mkOption {
        type = subnetType;
        default = { };
      };

      volumeSize = mkOption {
        type = ints.positive;
        default = 30;
      };

      securityGroupName = mkOption {
        type = str;
        default = "aws_security_group.${cfg.name}";
      };

      securityGroupId = mkOption {
        type = str;
        default = id this.config.securityGroupName;
      };

      securityGroupRules = mkOption {
        type = attrsOf (securityGroupRuleType {
          defaultSecurityGroupId = this.config.securityGroupId;
        });
        default = { };
      };

      initialVaultSecrets = mkOption {
        type = initialVaultSecretsType;
        default = { };
      };
    };
  });

  localExecType = submodule {
    options = {
      command = mkOption { type = str; };

      workingDir = mkOption {
        type = nullOr path;
        default = null;
      };

      interpreter = mkOption {
        type = nullOr (listOf str);
        default = [ "${pkgs.bash}/bin/bash" "-c" ];
      };

      environment = mkOption {
        type = attrsOf str;
        default = { };
      };
    };
  };

  autoscalingGroupType = submodule ({ name, ... }@this: {
    options = {
      name = mkOption {
        type = str;
        default = name;
      };

      uid = mkOption {
        type = str;
        default = "${cfg.name}-${this.config.name}";
      };

      modules = mkOption {
        type = listOf (oneOf [ path attrs ]);
        default = [ ];
      };

      ami = mkOption {
        type = str;
        default = autoscalingAMIs.${this.config.region} or (throw
          "Please make sure the NixOS ZFS AMI is copied to ${this.config.region}");
      };

      region = mkOption { type = str; };

      iam = mkOption { type = serverIamType this.config.name; };

      vpc = mkOption {
        type = vpcType this.config.uid;
        default = let base = toString (vpcMap.${this.config.region} * 4);
        in {
          region = this.config.region;

          cidr = "10.${base}.0.0/16";

          name = "${cfg.name}-${this.config.region}-asgs";
          subnets = {
            a.cidr = "10.${base}.0.0/18";
            b.cidr = "10.${base}.64.0/18";
            c.cidr = "10.${base}.128.0/18";
            # d.cidr = "10.${base}.192.0/18";
          };
        };
      };

      userData = mkOption {
        type = nullOr str;
        default = ''
          # amazon-shell-init
          set -exuo pipefail

          /run/current-system/sw/bin/zpool online -e tank nvme0n1p3

          export CACHES="https://hydra.iohk.io https://cache.nixos.org ${cfg.s3Cache}"
          export CACHE_KEYS="hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ= cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ${cfg.s3CachePubKey}"
          pushd /run/keys
          aws s3 cp "s3://${cfg.s3Bucket}/infra/secrets/${cfg.name}/${cfg.kms}/source/source.tar.xz" source.tar.xz
          mkdir -p source
          tar xvf source.tar.xz -C source

          # TODO: add git to the AMI
          nix build nixpkgs#git -o git
          export PATH="$PATH:$PWD/git/bin"

          nix build ./source#nixosConfigurations.${cfg.name}-${this.config.name}.config.system.build.toplevel --option substituters "$CACHES" --option trusted-public-keys "$CACHE_KEYS"
          /run/current-system/sw/bin/nixos-rebuild --flake ./source#${cfg.name}-${this.config.name} boot --option substituters "$CACHES" --option trusted-public-keys "$CACHE_KEYS"
          /run/current-system/sw/bin/shutdown -r now
        '';
      };

      minSize = mkOption {
        type = ints.unsigned;
        default = 0;
      };

      maxSize = mkOption {
        type = ints.unsigned;
        default = 10;
      };

      desiredCapacity = mkOption {
        type = ints.unsigned;
        default = 1;
      };

      maxInstanceLifetime = mkOption {
        type = oneOf [ (enum [ 0 ]) (ints.between 604800 31536000) ];
        default = 0;
      };

      instanceType = mkOption {
        type = str;
        default = "t3a.medium";
      };

      volumeSize = mkOption {
        type = ints.positive;
        default = 100;
      };

      volumeType = mkOption {
        type = str;
        default = "gp2";
      };

      tags = mkOption {
        type = attrsOf str;
        default = { };
      };

      associatePublicIP = mkOption {
        type = bool;
        default = true;
      };

      subnets = mkOption {
        type = listOf subnetType;
        default = builtins.attrValues this.config.vpc.subnets;
      };

      securityGroupId = mkOption {
        type = str;
        default = id "aws_security_group.${this.config.uid}";
      };

      securityGroupRules = mkOption {
        type = attrsOf (securityGroupRuleType {
          defaultSecurityGroupId = this.config.securityGroupId;
        });
        default = { };
      };
    };
  });
in {
  options = {
    cluster = mkOption {
      type = clusterType;
      default = { };
    };

    instance = mkOption {
      type = nullOr attrs;
      default = cfg.instances.${nodeName} or null;
    };

    asg = mkOption {
      type = nullOr attrs;
      default = cfg.autoscalingGroups.${nodeName} or null;
    };

    tf = lib.mkOption {
      default = { };
      type = attrsOf (submodule ({ name, ... }@this: {
        options = let
          copy = ''
            export PATH="${
              lib.makeBinPath [ pkgs.coreutils pkgs.terraform-with-plugins ]
            }"
            set -euo pipefail

            rm -f config.tf.json
            cp "${this.config.output}" config.tf.json
            chmod u+rw config.tf.json
          '';

          prepare = ''
            ${copy}

            terraform workspace select "${name}" 1>&2
            terraform init 1>&2
          '';
        in {
          configuration = lib.mkOption { type = attrsOf unspecified; };

          output = lib.mkOption {
            type = lib.mkOptionType { name = "${name}_config.tf.json"; };
            apply = v:
              let
                compiledConfig =
                  import (self.inputs.terranix + "/core/default.nix") {
                    pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux;
                    strip_nulls = false;
                    terranix_config = {
                      imports = [ this.config.configuration ];
                    };
                  };
              in pkgs.toPrettyJSON "${name}.tf" compiledConfig.config;
          };

          config = lib.mkOption {
            type = lib.mkOptionType { name = "${name}-config"; };
            apply = v: pkgs.writeShellScriptBin "${name}-config" copy;
          };

          plan = lib.mkOption {
            type = lib.mkOptionType { name = "${name}-plan"; };
            apply = v:
              pkgs.writeShellScriptBin "${name}-plan" ''
                ${prepare}

                terraform plan -out ${name}.plan
              '';
          };

          apply = lib.mkOption {
            type = lib.mkOptionType { name = "${name}-apply"; };
            apply = v:
              pkgs.writeShellScriptBin "${name}-apply" ''
                ${prepare}

                terraform apply ${name}.plan
              '';
          };

          terraform = lib.mkOption {
            type = lib.mkOptionType { name = "${name}-apply"; };
            apply = v:
              pkgs.writeShellScriptBin "${name}-apply" ''
                ${prepare}

                terraform $@
              '';
          };
        };
      }));
    };
  };
}
