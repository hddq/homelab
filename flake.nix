{
  description = "Homelab Playground - Full Auto Setup";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    topf = pkgs.stdenv.mkDerivation rec {
      pname = "topf";
      version = "0.6.0";
      src = pkgs.fetchurl {
        url = "https://github.com/postfinance/topf/releases/download/v${version}/topf_linux_amd64.tar.gz";
        hash = "sha256-RY30sl9BgaMe02HAWSGU9+uebnsT5wlvh0VFOv3qrfs=";
      };
      sourceRoot = ".";
      installPhase = ''
        install -m755 -D topf $out/bin/topf
      '';
    };

    talosctl = pkgs.stdenv.mkDerivation rec {
      pname = "talosctl";
      version = "1.14.0";
      src = pkgs.fetchurl {
        url = "https://github.com/siderolabs/talos/releases/download/v${version}/talosctl-linux-amd64";
        hash = "sha256-LBR8SpnRJMlb1cGQ/gVOCzyTSV8iQ/1lLr1COtuDd8c=";
      };
      dontUnpack = true;
      installPhase = ''
        install -m755 -D $src $out/bin/talosctl
      '';
    };
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        topf
        python3
        kubectl
        kubectl-cnpg
        kubernetes-helm
        kustomize
        kustomize-sops
        age
        sops
        argocd
        yamllint
        kubeconform
        trivy
        kubectx
        gitleaks
        pluto
        pre-commit
        shellcheck
        opentofu
        deploy-rs
        wireguard-tools
        qrencode
        statix
        deadnix
        alejandra
        ruff
        talosctl
        yq-go
        kyverno
        cilium-cli
        hubble
      ];

      shellHook = ''
        echo "🚀 Loading Homelab environment..."

        if [ ! -d .venv ]; then
          echo "🐍 Creating new venv..."
          python3 -m venv .venv
        fi
        source .venv/bin/activate

        pip install -r ansible/requirements.txt --disable-pip-version-check

        SITE_PACKAGES=$(find .venv/lib -name "site-packages" -type d | head -n 1)
        export PYTHONPATH="$(pwd)/$SITE_PACKAGES:$PYTHONPATH"

        export ANSIBLE_COLLECTIONS_PATH="$(pwd)/.ansible/collections"
        export ANSIBLE_ROLES_PATH="$(pwd)/.ansible/roles"

        if [ -f ansible/requirements.yaml ]; then
           echo "📦 Checking Ansible collections..."
           ansible-galaxy install -r ansible/requirements.yaml
        fi

        pre-commit install

        echo "✅ Ready! Python: $(which python)"
      '';
    };
    packages.${system}.talosctl = talosctl;
  };
}
