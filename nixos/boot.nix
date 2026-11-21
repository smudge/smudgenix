{ vars ? {} }:
{ config, ... }: let
  v = {
    windowsCompat = false;
  } // vars;
in {
  # Prefer GRUB:
  boot.loader = {
    systemd-boot.enable = false;
    efi.canTouchEfiVariables = true;
    grub = {
      enable = true;
      devices = ["nodev"];
      device = "nodev";
      efiSupport = true;
      extraEntries = ''
        menuentry "Reboot" {
          reboot
        }
        menuentry "Poweroff" {
          halt
        }
      '';
    };
  };

  # Show boot spinner:
  boot.kernelParams = ["quiet"];
  boot.plymouth.enable = true;

  # Dual boot with Windows:
  boot.loader.grub.useOSProber = v.windowsCompat;
  boot.supportedFilesystems = if v.windowsCompat then ["ntfs"] else [];
  time.hardwareClockInLocalTime = v.windowsCompat;
}
