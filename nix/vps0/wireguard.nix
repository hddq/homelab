{config, ...}: {
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking = {
    firewall.allowedUDPPorts = [51820];
    wireguard.interfaces = {
      wg0 = {
        ips = ["192.168.70.2/24"];
        listenPort = 51820;
        privateKeyFile = config.sops.secrets.wireguard_private_key.path;

        peers = [
          {
            # openwrt
            publicKey = "TCiRCR6qUTA/DiyCFsBFDJ+t5U2MfUf+ilJiFWrJe24=";
            allowedIPs = ["192.168.70.1/32" "192.168.40.0/24" "192.168.41.0/24" "192.168.10.0/24" "192.168.20.0/24"];
          }
          {
            # tundra
            publicKey = "kJWA/gR6RTYrJm+XMC1DDLuTq079SvVZE5QDST/qATc=";
            allowedIPs = ["192.168.70.15/32"];
          }
        ];
      };
    };
  };

  sops.secrets.wireguard_private_key = {};
}
