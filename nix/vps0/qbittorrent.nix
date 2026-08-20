{
  config,
  pkgs,
  ...
}: let
  portForwardScript = pkgs.writeScript "qbittorrent-port-forward.sh" ''
    #!/bin/sh
    PORT="$1"
    if [ -z "$PORT" ]; then
      echo "No port provided"
      exit 1
    fi
    echo "Updating qBittorrent listen port to $PORT..."

    for i in $(seq 1 30); do
      if curl -s -f -X POST --data "json={\"listen_port\":$PORT,\"random_port\":false,\"upnp\":false}" http://127.0.0.1:8080/api/v2/app/setPreferences; then
        echo "Successfully updated qBittorrent listen port to $PORT"
        exit 0
      fi
      echo "qBittorrent WebUI not ready yet, retrying in 2s ($i/30)..."
      sleep 2
    done

    echo "Failed to update qBittorrent listen port after 30 attempts"
    exit 1
  '';
in {
  boot.kernelModules = ["tun" "wireguard"];
  boot.kernel.sysctl."net.ipv4.conf.all.src_valid_mark" = 1;

  sops.secrets.pia_username = {};
  sops.secrets.pia_password = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/qbittorrent 0755 1000 1000 -"
    "d /var/lib/qbittorrent/config 0755 1000 1000 -"
    "d /var/lib/qbittorrent/downloads 0755 1000 1000 -"
  ];

  virtualisation.oci-containers.containers = {
    wireguard-pia = {
      image = "thrnz/docker-wireguard-pia:latest";
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--device=/dev/net/tun:/dev/net/tun"
        "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
      ];
      ports = [
        "192.168.70.2:8080:8080"
        "127.0.0.1:8080:8080"
      ];
      environment = {
        USER_FILE = "/run/secrets/pia_username";
        PASS_FILE = "/run/secrets/pia_password";
        LOC = "de-frankfurt";
        PORT_FORWARDING = "1";
        PORT_PERSIST = "1";
        PORT_SCRIPT = "/scripts/port-forward.sh";
        FIREWALL = "1";
        LOCAL_NETWORK = "192.168.0.0/16,10.0.0.0/25,172.16.0.0/12";
        KEEPALIVE = "25";
      };
      volumes = [
        "${config.sops.secrets.pia_username.path}:/run/secrets/pia_username:ro"
        "${config.sops.secrets.pia_password.path}:/run/secrets/pia_password:ro"
        "${portForwardScript}:/scripts/port-forward.sh:ro"
      ];
    };

    qbittorrent = {
      image = "ghcr.io/home-operations/qbittorrent:5.2.3";
      dependsOn = ["wireguard-pia"];
      user = "1000:1000";
      extraOptions = [
        "--network=container:wireguard-pia"
      ];
      volumes = [
        "/var/lib/qbittorrent/config:/config"
        "/var/lib/qbittorrent/downloads:/downloads"
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [8080];
}
