{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.extraServices.single_node_k3s.unifi;
  parent = config.extraServices.single_node_k3s;

  # Cert
  unifiCert = pkgs.writeText "20-unifi-cert.yaml" ''
    apiVersion: cert-manager.io/v1
    kind: Certificate
    metadata:
      name: unifi-tls
      namespace: default
    spec:
      secretName: unifi-tls-secret
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

  # Volume Mount (to keep settings)
  unifiPVs = pkgs.writeText "00-unifi-pvs.yaml" ''
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: unifi-config-pv
      labels:
        type: local
    spec:
      storageClassName: base
      capacity:
        storage: 4Gi
      accessModes:
        - ReadWriteMany
      persistentVolumeReclaimPolicy: Retain
      hostPath:
        path: "${cfg.config_path}"
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: unifi-config-pvc
      namespace: default
    spec:
      storageClassName: base
      accessModes:
        - ReadWriteMany
      resources:
        requests:
          storage: 4Gi
      volumeName: unifi-config-pv
  '';

  # Unifi service
  unifiHelmChart = pkgs.writeText "10-unifi-helmchart.yaml" ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: unifi
      namespace: kube-system
    spec:
      repo: https://k8s-at-home.com/charts/
      chart: unifi
      version: 5.1.2
      targetNamespace: default
      valuesContent: |
        image:
          repository: jacobalberty/unifi
          tag: v8.4.62
          pullPolicy: IfNotPresent

        env:
          TZ: "${config.time.timeZone}"
          PUID: "${toString cfg.uid}"
          PGID: "${toString cfg.gid}"
          UNIFI_UID: "${toString cfg.uid}"
          UNIFI_GID: "${toString cfg.gid}"

        persistence:
          data:
            enabled: true
            type: pvc
            existingClaim: unifi-config-pvc
            mountPath: /unifi
            ReadOnly: false

        hostNetwork: true
        dnsPolicy: ClusterFirstWithHostNet

        service:
          main:
            ports:
              http:
                enabled: true
                port: 8443
                nodePort: 8443
                targetPort: 8443
                protocol: HTTPS
              controller:
                enabled: true
                port: 8080
                nodePort: 8080
                targetPort: 8080
                protocol: TCP
              portal-http:
                enabled: true
                port: 8880
                nodePort: 8880
                targetPort: 8880
                protocol: HTTP
              portal-https:
                enabled: true
                port: 8843
                nodePort: 8843
                targetPort: 8843
                protocol: HTTPS
              speedtest:
                enabled: true
                port: 6789
                nodePort: 6789
                targetPort: 6789
                protocol: TCP
              stun:
                enabled: true
                port: 3478
                nodePort: 3478
                targetPort: 3478
                protocol: UDP
              syslog:
                enabled: true
                port: 5514
                nodePort: 5514
                targetPort: 5514
                protocol: UDP
              discovery:
                enabled: true
                port: 10001
                nodePort: 10001
                targetPort: 10001
                protocol: UDP
              discoverable:
                enabled: true
                port: 1900
                nodePort: 1900
                targetPort: 1900
                protocol: UDP

        ingress:
          main:
            enabled: true
            ingressClassName: nginx
            annotations:
              kubernetes.io/ingress.class: nginx
              nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
              nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
            tls:
              - secretName: unifi-tls-secret
                hosts:
                  - ${cfg.subdomain}.${parent.full_hostname}
                  - ${cfg.subdomain}.${parent.node_master_ip}.nip.io
            hosts:
              - host: ${cfg.subdomain}.${parent.full_hostname}
                paths:
                  - path: /
                    service:
                      name: unifi
                      port: 8443
              - host: ${cfg.subdomain}.${parent.node_master_ip}.nip.io
                paths:
                  - path: /
                    service:
                      name: unifi
                      port: 8443
  '';
in {
  options.extraServices.single_node_k3s.unifi = {
    enable = lib.mkEnableOption "Unifi Controller";

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = "unifi";
      example = "unifi";
      description = "Subdomain prefix used for the Unifi ingress (e.g. unifi.example.com).";
    };

    config_path = lib.mkOption {
      type = lib.types.str;
      example = "/mnt/kube/config/unifi";
      default = "/mnt/kube/config/unifi";
      description = "Path where configuration data will be saved";
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

  config = lib.mkIf cfg.enable {
    # Firewall rules
    networking.firewall.allowedTCPPorts = [
      8443 # Unifi - Web interface + API
      3478 # Unifi - STUN port
      10001 # Unifi - Device discovery
      8080 # Unifi - Controller
      1900 # Unifi - ???
      8843 # Unifi - Captive Portal (https)
      8880 # Unifi - Captive Portal (http)
      6789 # Unifi - Speedtest
      5514 # Unifi - remote syslog
    ];
    networking.firewall.allowedUDPPorts = [
      8443 # Unifi - Web interface + API
      3478 # Unifi - STUN port
      10001 # Unifi - Device discovery
      8080 # Unifi - Controller
      1900 # Unifi - ???
      8843 # Unifi - Captive Portal (https)
      8880 # Unifi - Captive Portal (http)
      6789 # Unifi - Speedtest
      5514 # Unifi - remote syslog
    ];

    # Chart files to automatically pick up
    systemd.tmpfiles.rules =
      [
        "L+ /var/lib/rancher/k3s/server/manifests/00-unifi-pvs.yaml - - - - ${unifiPVs}"
        "L+ /var/lib/rancher/k3s/server/manifests/10-unifi-helmchart.yaml - - - - ${unifiHelmChart}"
        "L+ /var/lib/rancher/k3s/server/manifests/20-unifi-cert.yaml - - - - ${unifiCert}"
      ]
      ++ [
        "d ${cfg.config_path} 0755 ${toString cfg.uid} ${toString cfg.gid} -"
      ];
  };
}
