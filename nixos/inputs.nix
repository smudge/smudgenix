{ vars ? {} }:
{ config, lib, pkgs, ... }: let
  v = {
  } // vars;
in {
  # Support trackpads.
  services.libinput.enable = true;

  # Set a faster key repeat.
  services.xserver = {
    autoRepeatDelay = 200;
    autoRepeatInterval = 25;
  };
}
