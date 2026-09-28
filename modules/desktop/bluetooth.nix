_: {
  flake.nixosModules.bluetooth = { ... }: {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = false;
    };

    # Make a Bluetooth device the default sink/source as soon as it connects, 
    # or when an A2DP/HFP profile switch recreates it. On disconnect WirePlumber's 
    # normal fallback picks the next-best node (speakers/headphones, built-in mic).
    #
    # For the mic, the node to pick is the "bluez_input.<addr>" loopback that
    # WirePlumber's headset-profile autoswitch creates: it exists even in A2DP
    # and flips the device to HFP only while something is recording. The raw
    # SCO nodes behind it are internal, and an A2DP source (a phone streaming
    # to us) isn't a mic, so both are skipped.
    services.pipewire.wireplumber.extraScripts."policy/bluetooth-switch-on-connect.lua" = ''
      log = Log.open_topic ("s-default-nodes")

      local function is_bt_mic (props)
        if props["bluez5.loopback"] == "true" then
          return true
        end
        -- autoswitch disabled: plain HFP source, unless we're the headset
        -- side of a phone call (headset-audio-gateway)
        return props["factory.name"] == "api.bluez5.sco.source"
          and props["api.bluez5.internal"] ~= "true"
          and props["api.bluez5.profile"] ~= "headset-audio-gateway"
      end

      SimpleEventHook {
        name = "policy/bluetooth-switch-on-connect",
        interests = {
          EventInterest {
            Constraint { "event.type", "=", "node-added" },
            Constraint { "media.class", "=", "Audio/Sink" },
            Constraint { "node.name", "#", "bluez_output.*" },
          },
          EventInterest {
            Constraint { "event.type", "=", "node-added" },
            Constraint { "media.class", "=", "Audio/Source" },
            Constraint { "node.name", "#", "bluez_input.*" },
          },
        },
        execute = function (event)
          local node = event:get_subject ()
          local props = node.properties
          local key
          if props["media.class"] == "Audio/Sink" then
            key = "default.configured.audio.sink"
          elseif is_bt_mic (props) then
            key = "default.configured.audio.source"
          else
            return
          end

          local om = event:get_source ():call ("get-object-manager", "metadata")
          local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
          if not metadata then
            return
          end

          local name = props["node.name"]
          log:info (node, "bluetooth node connected, making it default (" .. key .. "): " .. name)
          metadata:set (0, key, "Spa:String:JSON",
            Json.Object { ["name"] = name }:to_string ())
        end
      }:register ()
    '';

    services.pipewire.wireplumber.extraConfig."99-bluetooth-switch-on-connect" = {
      "wireplumber.components" = [
        {
          name = "policy/bluetooth-switch-on-connect.lua";
          type = "script/lua";
          provides = "custom.bluetooth-switch-on-connect";
        }
      ];
      "wireplumber.profiles" = {
        main."custom.bluetooth-switch-on-connect" = "required";
      };
    };
  };
}
