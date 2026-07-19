_: {
  # Mesa/EGL userspace drivers for all desktop hosts -- niri (via Smithay)
  # needs this for any accelerated rendering path. Without it, rendering
  # falls back to unaccelerated software compositing, which pegs a CPU core.
  flake.nixosModules.graphics = { ... }: {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
  };
}
