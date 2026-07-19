_: {
  # Per-host settings for the test VM. Mirrors framework-work's profile.
  flake.nixosModules.vmSettings = { ... }: {
    hostConfig = {
      hostName = "ato-vm";
      user.name = "ato";
      user.description = "ato";
      profile = "work";
      # git identity intentionally left unset for the throwaway VM.
    };
  };
}
