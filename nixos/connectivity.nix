{ vars ? {} }:
{ config, ... }: let
  v = vars // {
  };
in {
  # Enable networking.
  networking.networkmanager.enable = true;
  # networking.wireless.enable = true;

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable bluetooth.
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
}
