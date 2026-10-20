#!/usr/bin/python3
# L410: Mesa patches for Kirin 990 / Mali-G76 MC16:
# 1. Panfrost Gallium: converts private AFBC resources to u-interleaved on first CPU write
#    (reduces thousands of staging BO blits in Qt Quick / Plasma menu).
# 2. PanVK: enables Bifrost v7 (Mali-G76) without requiring PAN_I_WANT_A_BROKEN_VULKAN_DRIVER.
import os
import sys

def patch_gallium():
    P = "src/gallium/drivers/panfrost/pan_resource.c"
    if not os.path.exists(P):
        return
    s = open(P).read()
    if "pan_afbc_cpu_write_converts" in s:
        print("panfrost gallium already patched")
        return

    HELPER = r'''
/* L410: PAN_AFBC_CPU_WRITE=staging keeps the upstream staging-blit path for CPU
 * writes into AFBC resources (see panfrost_ptr_map). */
static bool
pan_afbc_cpu_write_converts(void)
{
   static int converts = -1;

   if (converts < 0) {
      const char *v = getenv("PAN_AFBC_CPU_WRITE");
      converts = !(v && !strcmp(v, "staging"));
   }
   return converts;
}

static void *
panfrost_ptr_map(struct pipe_context *pctx, struct pipe_resource *resource,
'''
    CONVERT = r'''   /* L410: every CPU write into an AFBC resource goes through a staging BO,
    * a blit and a flush (panfrost_ptr_unmap). Toolkits upload icons, glyphs
    * and images that way, texture after texture: a Qt Quick popup made
    * thousands of GPU submissions for its first frame. A private resource
    * the CPU writes to is better off u-interleaved: convert it on its first
    * CPU write, copying its contents if it has any, and let the CPU tile
    * from then on. */
   if ((usage & PIPE_MAP_WRITE) && drm_is_afbc(rsrc->modifier) &&
       pan_afbc_cpu_write_converts() && !rsrc->modifier_constant &&
       !(rsrc->bo->flags & PAN_BO_SHARED) &&
       !(resource->bind & (PIPE_BIND_SHARED | PIPE_BIND_SCANOUT |
                           PIPE_BIND_DISPLAY_TARGET | PIPE_BIND_DEPTH_STENCIL)) &&
       panfrost_should_tile(dev, rsrc, format)) {
      bool has_data = false;

      for (unsigned l = 0; l <= resource->last_level; ++l)
         has_data |= BITSET_TEST(rsrc->valid.data, l);

      pan_resource_modifier_convert(ctx, rsrc,
                                    DRM_FORMAT_MOD_ARM_16X16_BLOCK_U_INTERLEAVED,
                                    has_data, "CPU write to AFBC");
      bo = rsrc->bo;
   }

   /* We don't have s/w routines for AFBC/AFRC, so use a staging texture */
'''
    a = "\nstatic void *\npanfrost_ptr_map(struct pipe_context *pctx, struct pipe_resource *resource,\n"
    b = "   /* We don't have s/w routines for AFBC/AFRC, so use a staging texture */\n"
    if s.count(a) != 1 or s.count(b) != 1:
        print("gallium anchors not found, skipping gallium patch", file=sys.stderr)
        return
    s = s.replace(a, HELPER, 1).replace(b, CONVERT, 1)
    open(P, "w").write(s)
    print("panfrost gallium patched")

def patch_panvk():
    P_VK = "src/panfrost/vulkan/panvk_physical_device.c"
    if not os.path.exists(P_VK):
        return
    s = open(P_VK).read()
    if "/* L410: Mali-G76 (Bifrost v7) enabled */" in s:
        print("panvk already patched")
        return

    # In modern Mesa panvk, case 7: was in the warning check:
    #    case 6:
    #    case 7:
    #    ...
    # Move case 7: to the supported/accepted list:
    if "case 7:" in s and "PAN_I_WANT_A_BROKEN_VULKAN_DRIVER" in s:
        s = s.replace("   case 7:\n", "")
        if "   case 10:\n" in s:
            s = s.replace("   case 10:\n", "   case 7: /* L410: Mali-G76 (Bifrost v7) enabled */\n   case 10:\n", 1)
        elif "   case 9:\n" in s:
            s = s.replace("   case 9:\n", "   case 7: /* L410: Mali-G76 (Bifrost v7) enabled */\n   case 9:\n", 1)
        elif "   case 12:\n" in s:
            s = s.replace("   case 12:\n", "   case 7: /* L410: Mali-G76 (Bifrost v7) enabled */\n   case 12:\n", 1)
        open(P_VK, "w").write(s)
        print("panvk patched for Mali-G76 (Bifrost v7)")
    else:
        print("panvk check already permits v7 or format differs")

if __name__ == "__main__":
    patch_gallium()
    patch_panvk()
