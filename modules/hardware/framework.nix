_: {
  flake.nixosModules.frameworkHardware = { lib, pkgs, config, ... }: {
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

    # The ALC285 codec's unsolicited jack-detect interrupt is occasionally
    # missed/coalesced, so a headphone plugged in before or during playback
    # can get stuck routed to the speaker until a fresh unplug/replug edge
    # re-triggers detection. Poll the jack pin every 1s instead of relying
    # solely on the interrupt -- standard workaround for this class of
    # Realtek ALC2xx jack-sense bug.
    #
    # jackpoll_ms is a per-card array indexed by PCI probe order: index 0 is
    # the AMD GPU's HDMI/DP audio at 0000:c1:00.1, index 1 is the actual
    # Realtek ALC285 at 0000:c1:00.6. The leading comma is load-bearing --
    # it skips index 0 so the value lands on index 1, the card this
    # workaround actually targets.
    boot.extraModprobeConfig = ''
      options snd_hda_intel jackpoll_ms=0,1000
    '';

    # This card's "Headset Mic" pin (NID 0x19) has a BIOS pin-config bug
    # (Jack-Detect-Override forced on) that makes it always report present,
    # so ACP sometimes ranks a Headset-including profile ("HiFi (Headset,
    # Mic1, Speaker)", "HiFi (Headphones, Headset, Mic1)") above the correct
    # Mic1+Mic2 one, breaking mic capture until manually re-pinned via
    # `wpctl set-profile`. Fixing the pin itself at the kernel level (a
    # snd_hda_intel patch= pincfg override) worked for profile availability
    # but broke mic capture via a mixer-routing side effect (the driver's
    # own auto-routing started feeding the dead pin instead of the real
    # mic), so instead we just never let WirePlumber select a Headset
    # profile for this card, choosing between the two real profiles based
    # on the Headphones jack instead (which has always sensed correctly).
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

          -- Override anything already chosen if it's one of the fake
          -- profiles (e.g. a stale stored/user-selected pick).
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

    # The Lua hook above correctly picks the right profile whenever
    # WirePlumber actually re-evaluates one (device creation / wireplumber
    # restart) -- confirmed live. But a live headphone plug/unplug mid-session
    # updates this card's EnumRoute data promptly (confirmed via pw-dump)
    # without WirePlumber ever re-running profile selection for it -- ACP
    # appears to only push change notifications for routes that are part of
    # the *currently active* profile, so a route belonging to a
    # not-currently-selected profile (e.g. Headphones, while on the Speaker
    # profile) never triggers anything. A Lua hook keyed on that
    # notification was tried and confirmed not to fire.
    #
    # So: poll instead, same theme as the jackpoll_ms workaround above. Every
    # 2s, compare actual jack state (which is always correct on a fresh
    # query, per pw-dump) against the active profile, and self-correct via
    # wpctl if they disagree.
    #
    # Separately, this codec's OWN internal headset-mode detection logic
    # (Realtek's runtime impedance-sensing state machine, not anything in our
    # config) can spontaneously reroute its capture mixer (NID 0x23) to feed
    # the dead "Headset Mic" pin (0x19) instead of the real mic (0x12) --
    # observed once live with the profile already correct and no pincfg
    # patch active, likely destabilized by repeated jack plug/unplug. Poll
    # for and correct that too, using the verified AC_VERB_SET_AMP_GAIN_MUTE
    # encoding from include/sound/hda_verbs.h (AC_AMP_SET_INPUT=1<<14,
    # AC_AMP_SET_LEFT=1<<13, AC_AMP_SET_RIGHT=1<<12, AC_AMP_SET_INDEX=0xf<<8,
    # AC_AMP_MUTE=1<<7): 0x7080 = input|left|right|index0|mute (silence the
    # dead pin), 0x7400 = input|left|right|index4|unmute (restore the real
    # mic). hda-verb needs root for /dev/snd/hwC*D0, hence the narrowly
    # scoped NOPASSWD sudo rule below -- exact fixed commands only, not a
    # wildcard.
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
            /run/wrappers/bin/sudo ${pkgs.alsa-tools}/bin/hda-verb "$hw_dev" 0x23 SET_AMP_GAIN_MUTE 0x7080
            /run/wrappers/bin/sudo ${pkgs.alsa-tools}/bin/hda-verb "$hw_dev" 0x23 SET_AMP_GAIN_MUTE 0x7400
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
        commands = [
          {
            command = "${pkgs.alsa-tools}/bin/hda-verb /dev/snd/hwC0D0 0x23 SET_AMP_GAIN_MUTE 0x7080";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.alsa-tools}/bin/hda-verb /dev/snd/hwC0D0 0x23 SET_AMP_GAIN_MUTE 0x7400";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.alsa-tools}/bin/hda-verb /dev/snd/hwC1D0 0x23 SET_AMP_GAIN_MUTE 0x7080";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${pkgs.alsa-tools}/bin/hda-verb /dev/snd/hwC1D0 0x23 SET_AMP_GAIN_MUTE 0x7400";
            options = [ "NOPASSWD" ];
          }
        ];
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
