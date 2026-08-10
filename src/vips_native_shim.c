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
typedef struct _VipsArea VipsArea;
typedef struct _VipsArrayDouble VipsArrayDouble;

extern VipsImage *vips_image_new_from_file(const char *filename, ...);
extern int vips_image_get_width(VipsImage *image);
extern int vips_image_get_height(VipsImage *image);
extern int vips_smartcrop(VipsImage *in, VipsImage **out,
                          int width, int height, ...);
extern int vips_resize(VipsImage *in, VipsImage **out,
                       double scale, ...);
extern int vips_pngsave(VipsImage *in, const char *filename, ...);
extern int vips_flatten(VipsImage *in, VipsImage **out, ...);
extern int vips_embed(VipsImage *in, VipsImage **out,
                      int x, int y, int width, int height, ...);
extern VipsImage *vips_image_new_from_buffer(const void *buf, size_t len,
                                             const char *option_string, ...);
extern int vips_colourspace(VipsImage *in, VipsImage **out, int space, ...);
extern int vips_addalpha(VipsImage *in, VipsImage **out, ...);
extern int vips_pngsave_buffer(VipsImage *in, void **buf, size_t *len, ...);

extern VipsArrayDouble *vips_array_double_new(const double *array, int n);
extern void vips_area_unref(VipsArea *area);

/* GLib heap free — pairs with g_malloc, which vips_image_write_to_memory
 * uses for the buffer it returns. We expose a tiny shim so callers
 * don't need to bind libglib themselves. */
extern void g_free(void *mem);

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

/* Alpha-composite over a constant background colour. Caller passes
 * R, G, B, A as four doubles; libvips wraps them in a heap-allocated
 * VipsArrayDouble that we ref-down once we're done with the call. */
int
vips_shim_flatten(VipsImage *in, VipsImage **out,
                  double r, double g, double b)
{
    double bg[3] = {r, g, b};
    VipsArrayDouble *vbg = vips_array_double_new(bg, 3);
    int rc = vips_flatten(in, out, "background", vbg, NULL);
    vips_area_unref((VipsArea *)vbg);
    return rc;
}

/* Place `in` at (x,y) inside a (width, height) canvas, filling the
 * surrounding pixels with the constant (r,g,b) background. The
 * `extend` argument is a VipsExtend enum value; the caller is
 * expected to pass VIPS_EXTEND_BACKGROUND (5) here for the colour
 * fill to take effect. */
int
vips_shim_embed(VipsImage *in, VipsImage **out,
                int x, int y, int width, int height,
                int extend,
                double r, double g, double b)
{
    double bg[3] = {r, g, b};
    VipsArrayDouble *vbg = vips_array_double_new(bg, 3);
    int rc = vips_embed(in, out, x, y, width, height,
                        "extend", extend,
                        "background", vbg,
                        NULL);
    vips_area_unref((VipsArea *)vbg);
    return rc;
}

/* Decode an encoded image (PNG/JPEG/WebP/...) from an in-memory
 * buffer. libvips does NOT copy `buf` — it references it lazily, so
 * the caller must keep the buffer alive for the lifetime of the
 * returned VipsImage. The empty option_string takes loader defaults. */
VipsImage *
vips_shim_image_new_from_buffer(const void *buf, size_t len)
{
    return vips_image_new_from_buffer(buf, len, "", NULL);
}

/* Convert to a target colourspace (pass a VipsInterpretation enum
 * value, e.g. VIPS_INTERPRETATION_sRGB = 22). Normalises greyscale /
 * CMYK / 16-bit sources to 8-bit sRGB; any alpha band passes through
 * untouched. */
int
vips_shim_colourspace(VipsImage *in, VipsImage **out, int space)
{
    return vips_colourspace(in, out, space, NULL);
}

/* Append an opaque alpha channel if the image doesn't already have
 * one (no-op semantics are the caller's job — call only when bands < 4). */
int
vips_shim_addalpha(VipsImage *in, VipsImage **out)
{
    return vips_addalpha(in, out, NULL);
}

/* Encode `in` to PNG in memory. On success *buf points at a g_malloc'd
 * byte buffer of *len bytes; release it with vips_shim_free. */
int
vips_shim_pngsave_buffer(VipsImage *in, void **buf, size_t *len)
{
    return vips_pngsave_buffer(in, buf, len, NULL);
}

/* g_free wrapper. vips_image_write_to_memory returns a g_malloc'd
 * buffer; the caller releases it by calling back here. The NULL guard
 * matches GLib's own contract (g_free(NULL) is documented as a no-op,
 * but we belt-and-brace it). */
void
vips_shim_free(void *ptr)
{
    if (ptr) {
        g_free(ptr);
    }
}
