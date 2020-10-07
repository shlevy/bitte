{ lib, pkgs, config, ... }:
let
  inherit (config.cluster) domain region instances kms;
  acme-full = "/etc/ssl/certs/${config.cluster.domain}-full.pem";
in {
  imports = [
    ./common.nix
    ./consul/client.nix
    ./loki.nix
    ./telegraf.nix
    ./vault/client.nix
    ./secrets.nix
  ];

  services = {
    nomad.enable = false;
    vault-agent-core.enable = true;
    amazon-ssm-agent.enable = true;

    oauth2_proxy = {
      enable = true;
      extraConfig.whitelist-domain = ".${domain}";
      # extraConfig.github-org = "input-output-hk";
      # extraConfig.github-repo = "input-output-hk/mantis-ops";
      # extraConfig.github-user = "manveru,johnalotoski";
      extraConfig.pass-user-headers = "true";
      extraConfig.set-xauthrequest = "true";
      extraConfig.reverse-proxy = "true";
      provider = "google";
      keyFile = "/run/keys/oauth-secrets";

      email.domains = [ "iohk.io" ];
      cookie.domain = ".${domain}";
    };

    victoriametrics = {
      enable = true;
      retentionPeriod = 12; # months
    };

    loki = { enable = true; };

    grafana = {
      enable = true;
      auth.anonymous.enable = false;
      analytics.reporting.enable = false;
      addr = "";
      domain = "monitoring.${domain}";
      extraOptions = {
        AUTH_PROXY_ENABLED = "true";
        AUTH_PROXY_HEADER_NAME = "X-Authenticated-User";
        AUTH_SIGNOUT_REDIRECT_URL = "/oauth2/sign_out";
      };
      # rootUrl = "%(protocol)s://%(domain)s/grafana/";
      provision = {
        enable = true;

        datasources = [
          {
            type = "loki";
            name = "Loki";
            url = "http://localhost:3100";
            jsonData.maxLines = 1000;
          }
          {
            type = "prometheus";
            name = "VictoriaMetrics";
            url = "http://localhost:8428";
          }
        ];

        dashboards = [{
          name = "provisioned";
          options.path = ./monitoring;
        }];
      };

      security = { adminPasswordFile = /var/lib/grafana/password; };
    };

    prometheus = {
      exporters = {
        blackbox = {
          enable = true;
          configFile = pkgs.toPrettyJSON "blackbox-exporter" {
            modules = {
              https_2xx = {
                prober = "http";
                timeout = "5s";
                http = { fail_if_not_ssl = true; };
              };
            };
          };
        };
      };
    };
  };

  secrets.generate.grafana-password = ''
    export PATH="${lib.makeBinPath (with pkgs; [ coreutils sops xkcdpass ])}"

    if [ ! -s encrypted/grafana-password.json ]; then
      xkcdpass \
      | sops --encrypt --kms '${kms}' /dev/stdin \
      > encrypted/grafana-password.json
    fi
  '';

  secrets.install.grafana-password.script = ''
    export PATH="${lib.makeBinPath (with pkgs; [ sops coreutils ])}"

    mkdir -p /var/lib/grafana

    cat ${config.secrets.encryptedRoot + "/grafana-password.json"} \
      | sops -d /dev/stdin \
      > /var/lib/grafana/password
  '';

  users.extraGroups.keys.members = [ "oauth2_proxy" ];

  secrets.install.oauth.script = ''
    export PATH="${lib.makeBinPath (with pkgs; [ sops coreutils ])}"

    cat ${config.secrets.encryptedRoot + "/oauth-secrets"} \
      | sops -d /dev/stdin \
      > /run/keys/oauth-secrets

    chown root:keys /run/keys/oauth-secrets
    chmod g+r /run/keys/oauth-secrets
  '';

  systemd.services.ingress = let
    haproxyTemplate = pkgs.writeText "haproxy.conf.tmpl" ''
      global
        stats socket /run/ingress/haproxy.sock mode 600 expose-fd listeners level user
        log /dev/log local0 info
        lua-prepend-path ${pkgs.haproxy-auth-request}/usr/share/haproxy/?/http.lua
        lua-prepend-path ${pkgs.lua53Packages.dkjson}/share/lua/5.3/dk?.lua
        lua-load ${pkgs.haproxy-auth-request}/usr/share/haproxy/auth-request.lua

      defaults
        log global
        mode http
        option httplog
        option dontlognull
        timeout connect 5000
        timeout client 50000
        timeout server 50000
        default-server init-addr none
        balance roundrobin

      resolvers consul
        nameserver dnsmasq 127.0.0.1:53
        accepted_payload_size 8192
        hold valid 5s

      backend grafana
        default-server check maxconn 2000
        server grafana 127.0.0.1:3000

      backend oauth_proxy
        mode http
        server auth_request 127.0.0.1:4180 check

      backend nomad
        default-server ssl ca-file consul-ca.pem check check-ssl maxconn 2000
      {{ range service "http.nomad" }}
        server {{.ID}} {{.Address}}:{{.Port}}
      {{- end }}

      backend vault
        default-server ssl ca-file consul-ca.pem check check-ssl maxconn 2000 resolve-opts allow-dup-ip resolve-prefer ipv4 resolvers consul
      {{ range service "active.vault" }}
        server {{.ID}} {{.Address}}:{{.Port}}
      {{- end }}

      backend consul
        default-server check maxconn 2000
        option httpchk HEAD /
      {{ range $key, $value := service "consul" }}
        server consul{{ $key }} {{.Address}}:8500
      {{- end }}

      frontend stats
        bind *:1936
        stats uri /
        stats show-legends
        stats refresh 30s
        stats show-node
        no log

      frontend http
        bind *:80
        acl http ssl_fc,not
        http-request redirect scheme https if http

      frontend https
        bind *:443 ssl crt ${acme-full} alpn h2,http/1.1

        acl oauth_proxy path_beg /oauth2/
        acl authenticated var(txn.auth_response_successful) -m bool
        acl is_monitoring hdr(host) -i monitoring.${domain}
        acl is_vault     hdr(host) -i vault.${domain}
        acl is_nomad     hdr(host) -i nomad.${domain}
        acl is_consul    hdr(host) -i consul.${domain}
        acl is_ui path_beg /ui

        http-request lua.auth-request oauth_proxy /oauth2/auth
        http-request add-header X-Authenticated-User %[var(req.auth_response_header.x_auth_request_email)]

        use_backend oauth_proxy if oauth_proxy
        use_backend consul  if is_consul is_ui authenticated OR is_consul ! is_ui
        use_backend vault   if is_vault  is_ui authenticated OR is_vault ! is_ui
        use_backend nomad   if is_nomad  is_ui authenticated OR is_nomad ! is_ui
        use_backend oauth_proxy if is_ui ! authenticated OR is_monitoring ! authenticated

        default_backend grafana
    '';

    haproxyConfig = pkgs.toPrettyJSON "haproxy" {
      exec = [{ command = "${pkgs.haproxy}/bin/haproxy -f haproxy.conf"; }];
      template = [{
        source = haproxyTemplate;
        destination = "haproxy.conf";
      }];
    };
  in {
    wantedBy = [ "multi-user.target" ];
    after = [ "consul.service" ];

    serviceConfig = let
      preScript = pkgs.writeShellScriptBin "ingress-start-pre" ''
        export PATH="${lib.makeBinPath [ pkgs.coreutils ]}"
        set -exuo pipefail
        cp /etc/ssl/certs/cert-key.pem consul-key.pem
        cp /etc/ssl/certs/full.pem consul-ca.pem
        cat /etc/ssl/certs/{ca,cert,cert-key}.pem > consul-crt.pem

        cat /etc/ssl/certs/${config.cluster.domain}-{cert,key}.pem \
          ${../lib/letsencrypt.pem} \
        > acme-full.pem

        chown --reference . --recursive .
      '';
    in {
      StateDirectory = "ingress";
      RuntimeDirectory = "ingress";
      WorkingDirectory = "/var/lib/ingress";
      DynamicUser = true;
      User = "ingress";
      Group = "ingress";
      ProtectSystem = "full";
      TimeoutStopSec = "30s";
      RestartSec = "10s";
      Restart = "on-failure";
      StartLimitInterval = "20s";
      StartLimitBurst = 10;
      ExecStartPre = "!${preScript}/bin/ingress-start-pre";
      AmbientCapabilities = "CAP_NET_BIND_SERVICE";
    };

    path = with pkgs; [ consul consul-template vault-bin ];

    environment = {
      CONSUL_CACERT = "/etc/ssl/certs/full.pem";
      CONSUL_CLIENT_CERT = "/etc/ssl/certs/cert.pem";
      CONSUL_CLIENT_KEY = "consul-key.pem";
      CONSUL_HTTP_ADDR = "https://127.0.0.1:8501";
      CONSUL_HTTP_SSL = "true";
      VAULT_ADDR = "https://${config.cluster.instances.core-1.privateIP}:8200";
      inherit (config.environment.variables) VAULT_CACERT;
    };

    script = ''
      set -euo pipefail

      VAULT_TOKEN="$(vault login -method aws -no-store -token-only)"
      export VAULT_TOKEN
      CONSUL_HTTP_TOKEN="$(vault read -field token consul/creds/ingress)"
      export CONSUL_HTTP_TOKEN

      set -x

      exec consul-template -log-level debug -config ${haproxyConfig}
    '';
  };
}
