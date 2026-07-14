{
  config,
  lib,
  pkgs,
  ...
}: {
  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      server = {
        include = ["${../../shared/dns/unbound.conf}"];
      };
    };
  };

  networking.firewall.allowedTCPPorts = [5353];
  networking.firewall.allowedUDPPorts = [5353];
}
