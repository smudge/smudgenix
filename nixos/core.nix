{ pkgs, lib, ... }:

{
  # Use latest Linux kernel:
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Allow unfree packages and firmware (e.g. GPU, wifi & bluetooth blobs):
  nixpkgs.config.allowUnfree = true;
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
}
