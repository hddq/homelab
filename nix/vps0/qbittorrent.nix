_: {
  virtualisation.oci-containers.containers.qbittorrent = {
    image = "ghcr.io/home-operations/qbittorrent:5.2.3";
    ports = [
      "8080:8080"
      "6881:6881"
      "6881:6881/udp"
    ];
    volumes = [
      "/var/lib/qbittorrent/config:/config"
      "/var/lib/qbittorrent/downloads:/downloads"
    ];
  };

  networking.firewall.allowedTCPPorts = [8080 6881];
  networking.firewall.allowedUDPPorts = [6881];
}
