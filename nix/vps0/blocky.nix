_: {
  virtualisation.oci-containers.containers.blocky = {
    image = "ghcr.io/0xerr0r/blocky:v0.33.0";
    ports = [
      "53:53/tcp"
      "53:53/udp"
      "4000:4000/tcp"
    ];
    volumes = [
      "${../../shared/dns/blocky.yml}:/app/config.yml:ro"
    ];
  };

  networking.firewall.allowedTCPPorts = [53 4000];
  networking.firewall.allowedUDPPorts = [53];
}
