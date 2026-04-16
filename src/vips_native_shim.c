/*
 * vips_native_shim.c — non-variadic wrappers around libvips's
 * public C API for use from Raku NativeCall.
 *
 * libvips's entry points are all of the form:
 *
 *     VipsImage *vips_image_new_from_file(const char *filename, ...);
 *     int vips_smartcrop(VipsImage *in, VipsImage **out, int w, int h, ...);
 *     ...
 *
 * — variadic key/value option lists terminated with NULL. Raku's
 * NativeCall doesn't know a given C function is variadic, so it
 * marshals every declared argument according to the non-variadic
 * ABI. On Apple arm64 specifically, the variadic ABI is *different*
 * from the non-variadic ABI: named args go in registers (x0–x7),
 * unnamed / variadic args go on the stack. When NativeCall puts
 * our "NULL terminator" in a register (matching its declared
 * non-variadic sig), libvips reads the stack looking for varargs
 * and finds whatever garbage happens to be there — leading to
 * "pngload: no property named `<garbage>`" errors and NULL
 * returns. Linux x86_64 and Windows x64 happen not to exhibit the
 * bug because their variadic ABIs use the same registers as
 * non-variadic for the first several args, so the NULL we push
 * via a register is read correctly as the first vararg.
 *
 * The shim below gives each function an honest non-variadic
 * signature. NativeCall can then marshal it correctly on every
 * platform, and we pass NULL to the underlying variadic API
 * here in C where the compiler knows what it's doing.
 *
 * Exported symbols are prefixed `vips_shim_` to stay out of
 * libvips's namespace.
 */

#include <stddef.h>

/* Forward declarations matching libvips's public API. We avoid
 * including <vips/vips.h> because it transitively pulls GLib
 * headers and we don't want the compile-time dep surface here —
 * everything we need is the function signatures below, which
 * link-resolve to libvips.42.dylib at load time via the shim's
 * LC_LOAD_DYLIB. */

typedef struct _VipsImage VipsImage;

extern VipsImage *vips_image_new_from_file(const char *filename, ...);
extern int vips_image_get_width(VipsImage *image);
extern int vips_image_get_height(VipsImage *image);
extern int vips_smartcrop(VipsImage *in, VipsImage **out,
                          int width, int height, ...);
extern int vips_resize(VipsImage *in, VipsImage **out,
                       double scale, ...);
extern int vips_pngsave(VipsImage *in, const char *filename, ...);

/* --- wrappers ---------------------------------------------------- */

VipsImage *
vips_shim_image_new_from_file(const char *filename)
{
    return vips_image_new_from_file(filename, NULL);
}

int
vips_shim_smartcrop(VipsImage *in, VipsImage **out,
                    int width, int height, int interesting)
{
    return vips_smartcrop(in, out, width, height,
                          "interesting", interesting, NULL);
}

int
vips_shim_resize(VipsImage *in, VipsImage **out,
                 double scale, int kernel)
{
    return vips_resize(in, out, scale, "kernel", kernel, NULL);
}

int
vips_shim_pngsave(VipsImage *in, const char *filename)
{
    return vips_pngsave(in, filename, NULL);
}
