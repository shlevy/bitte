{ self, pkgs, config, lib, ... }: {
  imports = [
    ./common.nix
    ./consul/client.nix
    ./docker.nix
    ./nomad/client.nix
    ./telegraf.nix
    ./vault/client.nix
    ./secrets.nix
    ./reaper.nix
    ./builder.nix
    ./zfs-client-options.nix
  ];

  services = {
    amazon-ssm-agent.enable = true;
    vault-agent-client.enable = true;
    vault.enable = lib.mkForce false;
    nomad.enable = true;
    telegraf.extraConfig.global_tags.role = "consul-client";
    zfs-client-options.enable = true;
  };

  boot.cleanTmpDir = true;

  time.timeZone = "UTC";

  disabledModules = [ "virtualisation/amazon-image.nix" ];
  networking = { hostId = "9474d585"; };
  boot.initrd.postDeviceCommands = "echo FINDME; lsblk";
  boot.loader.grub.device = lib.mkForce "/dev/nvme0n1";
}
