{
  description = "NixOS configuration for Oracle Cloud vps0";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    deploy-rs,
    ...
  } @ inputs: {
    nixosConfigurations."vps0" = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = {inherit inputs;};
      modules = [
        disko.nixosModules.disko
        ./disk-config.nix
        ./configuration.nix
      ];
    };

    deploy.nodes.vps0 = {
      hostname = "vps0";
      remoteBuild = true;
      profiles.system = {
        user = "root";
        sshUser = "hddq";
        path = deploy-rs.lib.aarch64-linux.activate.nixos self.nixosConfigurations."vps0";
      };
    };
  };
}
