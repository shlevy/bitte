{ self, pkgs, config, lib, nodeName, ... }: {
  imports = [
    ./common.nix
    ./consul/server.nix
    ./nomad/server.nix
    ./telegraf.nix
    ./vault/server.nix
    ./secrets.nix
  ];

  services = {
    consul.enableDebug = false;
    consul.enable = true;
    nomad.enable = true;
    telegraf.extraConfig.global_tags.role = "consul-server";
    vault-agent-core.enable = true;
    vault-consul-token.enable = true;
  };
}
