{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.homepage;
  parent = config.extraServices.single_node_k3s;

  # Indent every non-empty line by N spaces (portable across nixpkgs versions)
  indentN = n: s: let
    pad = builtins.concatStringsSep "" (builtins.genList (_: " ") n);
    lines = lib.splitString "\n" s;
    indented = map (line:
      if line == ""
      then ""
      else pad + line)
    lines;
  in
    builtins.concatStringsSep "\n" indented;

  # Accept either Homepage's native list format or a shorthand attrset format.
  homepageBookmarks =
    if builtins.isList cfg.bookmarks
    then cfg.bookmarks
    else
      builtins.map
      (groupName: {
        ${groupName} =
          builtins.map
          (entryName: {${entryName} = [cfg.bookmarks.${groupName}.${entryName}];})
          (builtins.attrNames cfg.bookmarks.${groupName});
      })
      (builtins.attrNames cfg.bookmarks);

  bookmarksYaml = indentN 14 (lib.generators.toYAML {} homepageBookmarks);

  proxmoxServiceYaml = lib.optionalString (cfg.proxmox_widget != null) ''
    - Compute:
        - Proxmox:
            icon: proxmox.png
            href: https://${cfg.proxmox_widget.ip_address}:8006
            description: Proxmox Virtualization Server
            server: https://${cfg.proxmox_widget.ip_address}:8006
            siteMonitor: https://${cfg.proxmox_widget.ip_address}:8006
            widget:
              type: proxmox
              url: https://${cfg.proxmox_widget.ip_address}:8006
              username: ${cfg.proxmox_widget.monitor_username}
              password: ${cfg.proxmox_widget.monitor_password}
  '';

  # Cert
  homepageCert = pkgs.writeText "20-homepage-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: homepage-tls
      namespace: default
    spec:
      secretName: homepage-tls-secret
      issuerRef:
        kind: ClusterIssuer
        name: ca-cluster-issuer
      commonName: ${cfg.subdomain}.${parent.full_hostname}
      dnsNames:
        - ${cfg.subdomain}.${parent.full_hostname}
        - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
      duration: 2160h    # 90 days
      renewBefore: 360h  # 15 days before expiration
  '';

  # Chart
  homepageHelmChart = pkgs.writeText "10-homepage-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: homepage
      namespace: kube-system
    spec:
      repo: http://jameswynn.github.io/helm-charts
      chart: homepage
      version: 2.1.0
      targetNamespace: default
      valuesContent: |
        image:
          repository: ghcr.io/gethomepage/homepage
          tag: v1.5.0
          pullPolicy: IfNotPresent

        # Enable RBAC. RBAC is necessary to use Kubernetes integration
        enableRbac: true

        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          PASSWD: "admin"  # pragma: allowlist secret
          HOMEPAGE_ALLOWED_HOSTS: "${cfg.subdomain}.${parent.full_hostname}"
          NODE_TLS_REJECT_UNAUTHORIZED: 0

        persistence:
          logs:
            enabled: true
            type: emptyDir
            mountPath: ${cfg.log_path}

        serviceAccount:
          name: ""
          create: true

        service:
          main:
            ports:
              http:
                port: 3000

        ingress:
          main:
            enabled: true
            ingressClassName: nginx
            labels:
              gethomepage.dev/enabled: "true"
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              gethomepage.dev/name: "Homepage"
              gethomepage.dev/description: "A modern, secure, highly customizable application dashboard."
              gethomepage.dev/group: "Media"
              gethomepage.dev/icon: "homepage.png"
            tls:
              - secretName: homepage-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: homepage
                      port: 3000
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: homepage
                      port: 3000

        config:
          settings:
            background: https://images.unsplash.com/photo-1502790671504-542ad42d5189?auto=format&fit=crop&w=2560&q=80
          bookmarks:
    ${bookmarksYaml}
          services:
    ${indentN 14 proxmoxServiceYaml}${indentN 14 ''
      - Gaming:
          - Wolf Manager:
              icon: https://images.opencollective.com/games-on-whales/33a2797/logo/128.png
              href: http://nixoskubemini.home.arpa:3000
              description: Web UI for Games-on-whales Wolf
              siteMonitor: http://${parent.node_master_ip}:3000
    ''}
          widgets:
    ${indentN 12 ''
      - resources:
          backend: resources
          expanded: true
          cpu: true
          memory: true
      - search:
          provider: duckduckgo
          target: _blank
      - datetime:
          format:
            dateStyle: short
            timeStyle: short
            hour12: true
      - kubernetes:
          cluster:
            show: true
            cpu: true
            memory: true
            showLabel: true
            label: "cluster"
          nodes:
            show: true
            cpu: true
            memory: true
            showLabel: true
      - openmeteo:
          label: ${cfg.weather_widget.label}
          latitude: ${toString cfg.weather_widget.latitude}
          longitude: ${toString cfg.weather_widget.longitude}
          timezone: ${config.time.timeZone}
          units: ${cfg.weather_widget.units}
          cache: 180
          maximumFractionDigits: 1
    ''}
          kubernetes:
            mode: cluster
            gateway: true
  '';
in {
  options.extraServices.single_node_k3s.homepage = {
    enable = lib.mkEnableOption "Homepage Service";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "homepage";
      example = "homepage";
      description = "Subdomain prefix used for the Homepage ingress (e.g. homepage.example.com).";
    };

    log_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/homepage/logs";
      default = "/mnt/kube/config/homepage/logs";
      description = "Path where configuration data will be saved";
    };

    bookmarks = lib.mkOption {
      type = lib.types.anything;
      default = [];
      example = [
        {
          Communications = [
            {
              Discord = [
                {
                  icon = "discord.svg";
                  href = "https://discord.com";
                }
              ];
            }
          ];
        }
      ];
      description = ''
        Homepage bookmarks configuration.
        Accepts either Homepage's native list-of-group attrsets, or a shorthand
        attrset-of-attrsets which will be converted to Homepage's YAML format.
      '';
    };

    proxmox_widget = lib.mkOption {
      description = "Optional settings for the Homepage Proxmox widget.";
      type = lib.types.nullOr (lib.types.submodule ({lib, ...}: {
        options = {
          ip_address = lib.mkOption {
            type = lib.types.str;
            example = "192.168.1.10";
            default = "192.168.1.10";
            description = "Proxmox server IP";
          };

          monitor_username = lib.mkOption {
            type = lib.types.str;
            example = "homepage@pam!homepage";
            default = "homepage@pam!homepage";
            description = "Proxmox monitoring username (user must have PVEAuditor Role on Proxmox)";
          };

          monitor_password = lib.mkOption {
            type = lib.types.str;
            example = "password";
            default = "password";
            description = "Proxmox monitoring username's password";
          };
        };
      }));
      default = null;
      example = {
        ip_address = "192.168.1.10";
        monitor_username = "homepage@pam!homepage";
        monitor_password = "password"; # pragma: allowlist secret
      };
    };

    weather_widget = lib.mkOption {
      description = "Settings for the homepage weather widget.";
      type = lib.types.submodule ({lib, ...}: {
        options = {
          label = lib.mkOption {
            type = lib.types.str;
            default = "Olympia";
            example = "Location";
            description = "Display label for the widget.";
          };

          latitude = lib.mkOption {
            type = lib.types.float;
            default = 47.0449;
            example = 12.3456;
            description = "Latitude (−90..90).";
          };

          longitude = lib.mkOption {
            type = lib.types.float;
            default = -122.9017;
            example = 123.4567;
            description = "Longitude (−180..180).";
          };

          units = lib.mkOption {
            type = lib.types.enum ["imperial" "metric"];
            default = "imperial";
            example = "imperial";
            description = "Units system for the widget.";
          };
        };
      });
      # Whole-object default
      default = {
        label = "Olympia";
        latitude = 47.0449;
        longitude = -122.9017;
        units = "imperial";
      };
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "User id that accesses the mounted folders";
    };

    gid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      example = 1000;
      description = "Group id that accesses the mounted folders";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        # Chart files to automatically pick up
        "L+ /var/lib/rancher/k3s/server/manifests/10-homepage-helmchart.yaml - - - - ${homepageHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-homepage-cert.yaml - - - - ${homepageCert}"
        # Create folders and correct permissions
        "d ${cfg.log_path}  0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
    })
    (lib.mkIf (!cfg.enable) {
      systemd.tmpfiles.rules = [
        # Remove symbolic links of not enabled
        "r /var/lib/rancher/k3s/server/manifests/10-homepage-helmchart.yaml"
        "r /var/lib/rancher/k3s/server/manifests/20-homepage-cert.yaml"
      ];
    })
  ];
}
