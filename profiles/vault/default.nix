{ lib, pkgs, config, nodeName, ... }:
let
  inherit (config.cluster) region instances;
  instance = instances.${nodeName};
  cfg = config.services.vault;
in {
  config = lib.mkIf cfg.enable {
    environment.variables = {
      VAULT_FORMAT = "json";
      VAULT_CACERT = config.age.secrets.vault-full.path;
    };

    services.vault = {
      logLevel = "trace";

      clusterAddr = "https://${instance.privateIP}:8201";
      apiAddr = "https://${instance.privateIP}:8200";

      storage.raft = let
        vcfg = config.services.vault.listener.tcp;
        instances = lib.filterAttrs (k: v: lib.hasPrefix "core" k)
          config.cluster.instances;
      in {
        retryJoin = lib.mapAttrsToList (name: instance: {
          leaderApiAddr = "https://${instance.privateIP}:8200";
          leaderCaCertFile = config.age.secrets.vault-ca.path;
          leaderClientCertFile = config.age.secrets.vault-client.path;
          leaderClientKeyFile = config.age.secrets.vault-client-key.path;
        }) instances;
      };

      disableMlock = true;

      listener.tcp = {
        clusterAddress = "${instance.privateIP}:8201";
        address = "0.0.0.0:8200";
        tlsClientCaFile = config.age.secrets.vault-ca.path;
        tlsCertFile = config.age.secrets.vault-server.path;
        tlsKeyFile = config.age.secrets.vault-server-key.path;
        tlsMinVersion = "tls12";
      };

      telemetry = {
        disableHostname = true;
        dogstatsdAddr = "localhost:8125";
        dogstatsdTags = [ "region:${region}" "role:vault" ];
      };
    };
  };
}
