{ vars ? {} }:
{ config, pkgs, lib, ... }: let
  v = vars // {
    browser = "firefox";
    terminal = "alacritty";
    finder = "nemo";
    preview = "eog";
  };
in {
  # Use latest Linux kernel:
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Because nvidia:
  nixpkgs.config.allowUnfree = true;

  # Because intel:
  hardware.enableRedistributableFirmware = lib.mkDefault true;

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

  # Install all requisite packages
  environment.systemPackages = [
    pkgs.libsecret
    pkgs.${v.browser}
    pkgs.${v.terminal}
    pkgs.${v.finder}
    pkgs.${v.preview}
  ];
}
