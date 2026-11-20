_: {
  flake.nixosModules.frameworkHardware = { lib, pkgs, config, ... }:
  let
    hdaVerb = "${pkgs.alsa-tools}/bin/hda-verb";
    ampMuteDeadPin = "0x7080";
    ampUnmuteRealMic = "0x7400";
  in {
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usb_storage" "sd_mod" ];
    boot.kernelModules = [ "kvm-amd" ];

    hardware.enableRedistributableFirmware = true;
    services.fwupd.enable = true;
    services.fstrim.enable = true;
    zramSwap.enable = true;

    services.upower.enable = true;
    networking.firewall.enable = true;

    # The ALC285 sometimes misses its jack-detect interrupt (headphones stay on the speaker), so poll the pin.
    # jackpoll_ms is per card in PCI probe order: index 0 is the GPU's HDMI audio, index 1 the ALC285.
    boot.extraModprobeConfig = ''
      options snd_hda_intel jackpoll_ms=0,1000
    '';

    # BIOS pin-config bug: the Headset Mic pin (NID 0x19) always reports present, so ACP may rank a Headset
    # profile first and break capture; a kernel pincfg override broke mixer routing instead, so WirePlumber
    # never picks a Headset profile here and goes by the Headphones jack, which senses correctly.
    services.pipewire.wireplumber.extraScripts."device/fix-alc285-headset-mic.lua" = ''
      cutils = require ("common-utils")
      log = Log.open_topic ("s-device")

      SimpleEventHook {
        name = "device/fix-alc285-headset-mic",
        after = { "device/find-stored-profile", "device/find-preferred-profile" },
        before = "device/find-best-profile",
        interests = {
          EventInterest {
            Constraint { "event.type", "=", "select-profile" },
          },
        },
        execute = function (event)
          local device = event:get_subject ()
          if device.properties["device.name"] ~= "alsa_card.pci-0000_c1_00.6" then
            return
          end

          local selected_profile = event:get_data ("selected-profile")
          if selected_profile and selected_profile.name:find ("Headset") then
            selected_profile = nil
          end
          if selected_profile then
            return
          end

          local hp_available = "unknown"
          for p in device:iterate_params ("EnumRoute") do
            local route = cutils.parseParam (p, "EnumRoute")
            if route and route.name == "[Out] Headphones" then
              hp_available = route.available
            end
          end

          local want_name = (hp_available == "yes")
            and "HiFi (Headphones, Mic1, Mic2)"
            or  "HiFi (Mic1, Mic2, Speaker)"

          for p in device:iterate_params ("EnumProfile") do
            local profile = cutils.parseParam (p, "EnumProfile")
            if profile and profile.name == want_name then
              log:info (device, "alc285 fixup: selecting '" .. want_name .. "'")
              event:set_data ("selected-profile", profile)
              return
            end
          end
        end
      }:register()
    '';

    services.pipewire.wireplumber.extraConfig."99-alc285-headset-fixup" = {
      "wireplumber.components" = [
        {
          name = "device/fix-alc285-headset-mic.lua";
          type = "script/lua";
          provides = "custom.alc285-headset-fixup";
        }
      ];
      "wireplumber.profiles" = {
        main."custom.alc285-headset-fixup" = "required";
      };
    };

    # ACP only notifies route changes of the active profile, so a headphone plug never re-runs profile
    # selection: poll. The codec's own headset-mode detection can also reroute its capture mixer (NID 0x23)
    # to the dead pin; hda-verb needs root for /dev/snd/hwC*D0, values from include/sound/hda_verbs.h.
    systemd.user.services.fix-alc285-profile-poll = {
      description = "Keep ALC285 audio profile and mixer routing matched to real jack state";
      script = ''
        set -euo pipefail

        codec_proc="$(${pkgs.gnugrep}/bin/grep -l "Realtek ALC285" /proc/asound/card*/codec#* 2>/dev/null | head -1)"
        if [ -n "$codec_proc" ]; then
          hw_dev="/dev/snd/hwC$(echo "$codec_proc" | ${pkgs.gnugrep}/bin/grep -oP 'card\K[0-9]+')D0"
          mixer_line="$(${pkgs.gawk}/bin/awk '/^Node 0x23 /{f=1} f && /Amp-In vals/{print; exit}' "$codec_proc")"
          dead_pin_val="$(echo "$mixer_line" | ${pkgs.gnugrep}/bin/grep -oP '\[0x[0-9a-f]+ 0x[0-9a-f]+\]' | head -1)"
          if [ "$dead_pin_val" = "[0x00 0x00]" ]; then
            /run/wrappers/bin/sudo ${hdaVerb} "$hw_dev" 0x23 SET_AMP_GAIN_MUTE ${ampMuteDeadPin}
            /run/wrappers/bin/sudo ${hdaVerb} "$hw_dev" 0x23 SET_AMP_GAIN_MUTE ${ampUnmuteRealMic}
          fi
        fi

        json="$(${pkgs.pipewire}/bin/pw-dump)"
        device_json="$(echo "$json" | ${pkgs.jq}/bin/jq -c '
          .[] | select(.info.props["device.name"]? == "alsa_card.pci-0000_c1_00.6")
        ')"
        [ -z "$device_json" ] && exit 0

        device_id="$(echo "$device_json" | ${pkgs.jq}/bin/jq -r '.id')"
        hp_available="$(echo "$device_json" | ${pkgs.jq}/bin/jq -r '
          .info.params.EnumRoute[]? | select(.name == "[Out] Headphones") | .available
        ' | head -1)"

        if [ "$hp_available" = "yes" ]; then
          want_name="HiFi (Headphones, Mic1, Mic2)"
        else
          want_name="HiFi (Mic1, Mic2, Speaker)"
        fi

        current_name="$(echo "$device_json" | ${pkgs.jq}/bin/jq -r '.info.params.Profile[0].name // empty')"
        [ "$current_name" = "$want_name" ] && exit 0

        want_index="$(echo "$device_json" | ${pkgs.jq}/bin/jq -r --arg n "$want_name" '
          .info.params.EnumProfile[]? | select(.name == $n) | .index
        ' | head -1)"
        [ -z "$want_index" ] && exit 0

        ${pkgs.wireplumber}/bin/wpctl set-profile "$device_id" "$want_index"
      '';
      serviceConfig.Type = "oneshot";
    };

    security.sudo.extraRules = [
      {
        users = [ config.hostConfig.user.name ];
        commands = lib.concatMap (card: map (gain: {
          command = "${hdaVerb} /dev/snd/hwC${card}D0 0x23 SET_AMP_GAIN_MUTE ${gain}";
          options = [ "NOPASSWD" ];
        }) [ ampMuteDeadPin ampUnmuteRealMic ]) [ "0" "1" ];
      }
    ];

    systemd.user.timers.fix-alc285-profile-poll = {
      description = "Poll headphone jack state for the ALC285 profile fixup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5s";
        OnUnitActiveSec = "2s";
      };
    };
  };
}
