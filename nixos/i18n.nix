{ vars ? {} }:
{ config, ... }: let
  v = {
    locale = "en_US.UTF-8";
  } // vars;
in {
  i18n.defaultLocale = v.locale;
  i18n.extraLocaleSettings = {
    LC_ADDRESS = v.locale;
    LC_IDENTIFICATION = v.locale;
    LC_MEASUREMENT = v.locale;
    LC_MONETARY = v.locale;
    LC_NAME = v.locale;
    LC_NUMERIC = v.locale;
    LC_PAPER = v.locale;
    LC_TELEPHONE = v.locale;
    LC_TIME = v.locale;
  };
}
