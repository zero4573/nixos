_: {
  flake.nixosModules.frameworkHardware = { lib, pkgs, ... }: {
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
    systemd.user.services.fix-alc285-profile-poll = {
      description = "Keep ALC285 audio profile matched to real headphone jack state";
      script = ''
        set -euo pipefail
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
