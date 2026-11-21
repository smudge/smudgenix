{ config, pkgs, lib, ... }:

let
  cfg = config.smudgenix.apps;
in
{
  options.smudgenix.apps = {
    browser = lib.mkPackageOption pkgs "firefox" { };
    terminal = lib.mkPackageOption pkgs "alacritty" { };
    fileManager = lib.mkPackageOption pkgs "nemo" { };
    imageViewer = lib.mkPackageOption pkgs "eog" { };
  };

  config = {
    # Use latest Linux kernel:
    boot.kernelPackages = pkgs.linuxPackages_latest;

    # Because nvidia:
    nixpkgs.config.allowUnfree = true;

    # Because intel:
    hardware.enableRedistributableFirmware = lib.mkDefault true;

    # Support flakes, and go flake-only (no channels; <nixpkgs> resolves to
    # the system's flake nixpkgs):
    nix = {
      extraOptions = ''
        experimental-features = nix-command flakes
      '';
      channel.enable = false;
    };

    # Disable the NixOS documentation app.
    documentation.nixos.enable = false;

    # Monitor & control temps:
    services.thermald.enable = true;

    # Use libsecret and launch gnome-keyring at startup.
    programs.dconf.enable = true;
    programs.seahorse.enable = true;
    services.gnome.gnome-keyring.enable = true;
    security.pam.services.gdm.enableGnomeKeyring = true;

    # Install git and use libsecret.
    programs.git = {
      enable = true;
      package = pkgs.gitFull;
      config.credential.helper = "libsecret";
    };

    # Install neovim by default, and alias vi/vim.
    programs.neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
    };

    # Default desktop apps:
    environment.systemPackages = [
      pkgs.libsecret
      cfg.browser
      cfg.terminal
      cfg.fileManager
      cfg.imageViewer
    ];
  };
}
