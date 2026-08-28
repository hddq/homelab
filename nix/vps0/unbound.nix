_: {
  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      server = {
        include = ["${../../shared/dns/unbound.conf}"];
      };
    };
  };

  services.prometheus.exporters.unbound = {
    enable = true;
    openFirewall = true;
  };

  networking.firewall.allowedTCPPorts = [5353 9167];
  networking.firewall.allowedUDPPorts = [5353];
}
