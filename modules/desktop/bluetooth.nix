_: {
  flake.nixosModules.bluetooth = { ... }: {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = false;
    };

    services.pipewire.wireplumber.extraScripts."policy/bluetooth-switch-on-connect.lua" = ''
      log = Log.open_topic ("s-default-nodes")

      SimpleEventHook {
        name = "policy/bluetooth-switch-on-connect",
        interests = {
          EventInterest {
            Constraint { "event.type", "=", "node-added" },
            Constraint { "media.class", "=", "Audio/Sink" },
            Constraint { "node.name", "#", "bluez_output.*" },
          },
        },
        execute = function (event)
          local node = event:get_subject ()
          local key = "default.configured.audio.sink"

          local om = event:get_source ():call ("get-object-manager", "metadata")
          local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
          if not metadata then
            return
          end

          local name = node.properties["node.name"]
          log:info (node, "bluetooth sink connected, making it default: " .. name)
          metadata:set (0, key, "Spa:String:JSON",
            Json.Object { ["name"] = name }:to_string ())
        end
      }:register ()

      -- Teams always opens its stream on a named device (target.object) and reopens it there when devices
      -- change; a target.object of -1 in the default metadata overrides it (linking/find-defined-target.lua)
      SimpleEventHook {
        name = "policy/chromium-output-follows-default",
        interests = {
          EventInterest {
            Constraint { "event.type", "=", "node-added" },
            Constraint { "media.class", "=", "Stream/Output/Audio" },
            Constraint { "application.process.binary", "#", "*chromium*" },
          },
        },
        execute = function (event)
          local node = event:get_subject ()
          local om = event:get_source ():call ("get-object-manager", "metadata")
          local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
          if not metadata then
            return
          end

          log:info (node, "chromium output stream, following the default sink: "
            .. tostring (node.properties ["node.name"]))
          metadata:set (node ["bound-id"], "target.object", "Spa:Id", "-1")
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
