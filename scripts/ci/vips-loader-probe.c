/*
 * vips-loader-probe.c — release gate for a staged Vips-Native bundle.
 *
 *     vips-loader-probe <libvips> <stage-dir> <work-dir>
 *
 * Loads <libvips> the way NativeCall does (dlopen by absolute path, no
 * link-time dependency on anything), initialises it, and then proves the
 * bundle can actually open every format it is meant to:
 *
 *   1. Each loader operation is registered: pngload, jpegload, webpload,
 *      tiffload, gifload, svgload (built into libvips) and heifload,
 *      jxlload, openslideload, pdfload (the dlopen'd vips-modules — the
 *      ones a bundle silently loses when the module directory or one
 *      module's dependency is missing). And magickload is NOT: the macOS
 *      and Linux bundles leave out conda-forge's ImageMagick module, and
 *      everything only it links (Graphviz, EPL-1.0, among them), so a
 *      magickload here means one of those came back.
 *   2. Each loader decodes a real file: a fixture is written into
 *      <work-dir> (by a libvips saver where one exists, by hand for GIF,
 *      PDF and SVG, which these builds have no saver for), loaded
 *      through that loader BY NAME — so a format sniffed by another
 *      loader cannot stand in for it — and every pixel is computed
 *      (vips_avg), not just the header read.
 *   3. Nothing was loaded from outside the bundle: every image in the
 *      process is the probe itself, a system library, or a file under
 *      <stage-dir>. A dependency the bundler missed would otherwise be
 *      found on the build machine (a Homebrew or conda copy) and pass.
 *
 * Exit status 0 only when all of it holds. The caller sets the
 * environment FFI.rakumod sets for a staged bundle (VIPSHOME,
 * GIO_MODULE_DIR); see scripts/ci/probe-bundle.sh.
 *
 * Plain C99 + dlopen; builds with the platform cc on macOS and glibc
 * Linux. No libvips headers: the handful of entry points used are
 * declared here, as src/vips_native_shim.c does.
 */

#define _GNU_SOURCE /* realpath() under -std=c99 on glibc */

#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

typedef struct _VipsImage VipsImage;
typedef unsigned long GType; /* gsize; this probe only targets LP64 */

static int (*p_vips_init)(const char *argv0);
static const char *(*p_vips_version_string)(void);
static GType (*p_vips_type_find)(const char *basename, const char *nickname);
static const char *(*p_vips_error_buffer)(void);
static void (*p_vips_error_clear)(void);
static int (*p_vips_black)(VipsImage **out, int width, int height, ...);
static int (*p_vips_image_write_to_file)(VipsImage *in, const char *name, ...);
static int (*p_vips_tiffsave)(VipsImage *in, const char *filename, ...);
static int (*p_vips_call)(const char *operation_name, ...);
static int (*p_vips_avg)(VipsImage *in, double *out, ...);
static int (*p_vips_image_get_width)(const VipsImage *image);
static int (*p_vips_image_get_height)(const VipsImage *image);
static void (*p_g_object_unref)(void *object);

static int failures = 0;

static void
fail(const char *what)
{
    const char *err = p_vips_error_buffer ? p_vips_error_buffer() : "";
    printf("FAIL: %s%s%s\n", what, err && *err ? "\n      " : "", err ? err : "");
    if (p_vips_error_clear)
        p_vips_error_clear();
    failures++;
}

static void *
need(void *lib, const char *symbol)
{
    void *p = dlsym(lib, symbol);
    if (!p) {
        printf("FAIL: libvips has no %s: %s\n", symbol, dlerror());
        exit(2);
    }
    return p;
}

static void
path_join(char *out, size_t size, const char *dir, const char *name)
{
    if ((size_t) snprintf(out, size, "%s/%s", dir, name) >= size) {
        printf("FAIL: path too long: %s/%s\n", dir, name);
        exit(2);
    }
}

static int
write_text(const char *path, const char *text, size_t len)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    size_t n = fwrite(text, 1, len, f);
    return (fclose(f) == 0 && n == len) ? 0 : -1;
}

/* A one-page PDF, 72 x 72 pt (72 x 72 px at pdfload's default 72 dpi),
 * holding one filled rectangle; the cross-reference offsets are computed,
 * not hard-coded, so poppler reads it without falling back to repair. */
static int
write_pdf(const char *path)
{
    static const char stream[] = "0.2 0.4 0.6 rg 8 8 56 56 re f\n";
    char objs[4][256];
    snprintf(objs[0], sizeof objs[0],
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    snprintf(objs[1], sizeof objs[1],
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n");
    snprintf(objs[2], sizeof objs[2],
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] "
        "/Resources << >> /Contents 4 0 R >>\nendobj\n");
    snprintf(objs[3], sizeof objs[3],
        "4 0 obj\n<< /Length %zu >>\nstream\n%sendstream\nendobj\n",
        strlen(stream), stream);

    char pdf[2048];
    size_t len = 0, offsets[4];
    len += (size_t) snprintf(pdf + len, sizeof pdf - len, "%%PDF-1.4\n");
    for (int i = 0; i < 4; i++) {
        offsets[i] = len;
        len += (size_t) snprintf(pdf + len, sizeof pdf - len, "%s", objs[i]);
    }
    size_t xref = len;
    len += (size_t) snprintf(pdf + len, sizeof pdf - len,
        "xref\n0 5\n0000000000 65535 f \n");
    for (int i = 0; i < 4; i++)
        len += (size_t) snprintf(pdf + len, sizeof pdf - len,
            "%010zu 00000 n \n", offsets[i]);
    len += (size_t) snprintf(pdf + len, sizeof pdf - len,
        "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n%zu\n%%%%EOF\n", xref);
    if (len >= sizeof pdf)
        return -1;
    return write_text(path, pdf, len);
}

/* A <w> x <h> GIF89a (w, h <= 255) of four colours, written without
 * compression: its LZW stream sends a clear code before every pixel, so
 * the decoder's code table never grows past its initial 3-bit codes and no
 * encoder is needed. These builds have no GIF saver (no cgif). */
static int
write_gif(const char *path, int w, int h)
{
    unsigned char gif[8192];
    size_t len = 0;
    static const unsigned char head[] = {
        'G', 'I', 'F', '8', '9', 'a',
        0, 0, 0, 0,          /* logical screen width, height: below */
        0x91, 0, 0,          /* global colour table of 4, colour resolution 2 */
        0x20, 0x40, 0x80,    /* the colours */
        0xc0, 0x60, 0x30,
        0x10, 0xa0, 0x50,
        0xf0, 0xf0, 0xf0,
        0x2c, 0, 0, 0, 0,    /* image descriptor at 0, 0 */
        0, 0, 0, 0,          /* image width, height: below */
        0,                   /* no local colour table, not interlaced */
        2,                   /* LZW minimum code size: clear 4, end 5 */
    };
    unsigned char data[4096];
    size_t nbits = 0;

    if (w < 1 || h < 1 || w > 255 || h > 255
        || (size_t) w * h * 6 + 3 > sizeof data * 8)
        return -1;
    memcpy(gif, head, sizeof head);
    gif[6] = gif[30] = (unsigned char) w;
    gif[8] = gif[32] = (unsigned char) h;
    len = sizeof head;

    memset(data, 0, sizeof data);
#define PUT_CODE(c) \
    do { \
        for (int b_ = 0; b_ < 3; b_++, nbits++) \
            if (((c) >> b_) & 1) \
                data[nbits / 8] |= (unsigned char) (1u << (nbits % 8)); \
    } while (0)
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            PUT_CODE(4);               /* clear */
            PUT_CODE((x + y) % 4);     /* the pixel's colour index */
        }
    PUT_CODE(5);                       /* end of information */
#undef PUT_CODE
    size_t nbytes = (nbits + 7) / 8;
    for (size_t at = 0; at < nbytes; at += 255) {
        size_t chunk = nbytes - at < 255 ? nbytes - at : 255;
        if (len + 1 + chunk + 2 > sizeof gif)
            return -1;
        gif[len++] = (unsigned char) chunk;
        memcpy(gif + len, data + at, chunk);
        len += chunk;
    }
    gif[len++] = 0;                    /* block terminator */
    gif[len++] = 0x3b;                 /* trailer */
    return write_text(path, (const char *) gif, len);
}

static int
write_svg(const char *path)
{
    static const char svg[] =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"30\">"
        "<rect width=\"40\" height=\"30\" fill=\"#3366cc\"/></svg>\n";
    return write_text(path, svg, sizeof svg - 1);
}

/* Load <path> through the loader called <loader>, compute every pixel,
 * and check the size. */
static void
load_by_name(const char *loader, const char *path, int want_w, int want_h)
{
    char what[PATH_MAX + 64];
    VipsImage *out = NULL;
    double avg = 0.0;

    p_vips_error_clear(); /* sniffing by earlier calls leaves noise behind */
    snprintf(what, sizeof what, "%s could not load %s", loader, path);
    if (p_vips_call(loader, path, &out, NULL) != 0 || !out) {
        fail(what);
        return;
    }
    snprintf(what, sizeof what, "%s could not decode the pixels of %s", loader, path);
    if (p_vips_avg(out, &avg, NULL) != 0) {
        fail(what);
        p_g_object_unref(out);
        return;
    }
    int w = p_vips_image_get_width(out), h = p_vips_image_get_height(out);
    p_g_object_unref(out);
    if (w != want_w || h != want_h) {
        printf("FAIL: %s loaded %s as %dx%d, expected %dx%d\n",
            loader, path, w, h, want_w, want_h);
        failures++;
        return;
    }
    printf("ok:   %-14s %dx%d, mean %.2f  (%s)\n", loader, w, h, avg, path);
}

/* Write <img> to <dir>/<name> with <saver> called by name (the libvips
 * name, or NULL for "pick by suffix"), then load it back through
 * <loader>. */
static void
round_trip(VipsImage *img, const char *dir, const char *name,
    const char *saver, const char *format, const char *loader)
{
    char path[PATH_MAX];
    char what[PATH_MAX + 64];
    int rc;

    path_join(path, sizeof path, dir, name);
    p_vips_error_clear();
    if (saver && format)
        rc = p_vips_call(saver, img, path, "format", format, NULL);
    else if (saver)
        rc = p_vips_call(saver, img, path, NULL);
    else
        rc = p_vips_image_write_to_file(img, path, NULL);
    if (rc != 0) {
        snprintf(what, sizeof what, "could not write the %s fixture %s", loader, path);
        fail(what);
        return;
    }
    load_by_name(loader, path, p_vips_image_get_width(img), p_vips_image_get_height(img));
}

/* --- 3. what the process loaded ------------------------------------- */

static char stage_real[PATH_MAX];
static size_t stage_len;

static int
is_system_path(const char *name)
{
    static const char *system_dirs[] = {
#if defined(__APPLE__)
        "/usr/lib/", "/System/", "/Library/Apple/System/",
#else
        "/lib/", "/lib64/", "/usr/lib/", "/usr/lib64/",
#endif
        NULL
    };
    for (int i = 0; system_dirs[i]; i++)
        if (strncmp(name, system_dirs[i], strlen(system_dirs[i])) == 0)
            return 1;
    return 0;
}

static int loaded_count = 0, loaded_from_stage = 0;

static void
check_loaded(const char *name)
{
    char real[PATH_MAX];

    if (!name || name[0] != '/')
        return;
    loaded_count++;
    if (is_system_path(name))
        return;
    if (realpath(name, real) && strncmp(real, stage_real, stage_len) == 0
        && real[stage_len] == '/') {
        loaded_from_stage++;
        return;
    }
    printf("FAIL: loaded from outside the bundle: %s\n", name);
    failures++;
}

static void
check_process_images(void)
{
#if defined(__APPLE__)
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 1; i < n; i++) /* 0 is the probe itself */
        check_loaded(_dyld_get_image_name(i));
#elif defined(__linux__)
    /* The files mapped executable, rather than the dynamic linker's list:
     * glibc names an object by the path it was found through, and that
     * can be a directory spelling ("<dir>/..") rather than the file. A
     * mapping names the file itself. */
    char exe[PATH_MAX] = "";
    if (!realpath("/proc/self/exe", exe))
        exe[0] = '\0';
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) {
        printf("FAIL: cannot read /proc/self/maps\n");
        failures++;
        return;
    }
    char line[PATH_MAX + 256], last[PATH_MAX] = "";
    while (fgets(line, sizeof line, maps)) {
        char perms[8];
        int path_at = 0;
        if (sscanf(line, "%*s %7s %*s %*s %*s %n", perms, &path_at) < 1 || path_at == 0)
            continue;
        char *path = line + path_at;
        path[strcspn(path, "\n")] = '\0';
        if (!strchr(perms, 'x') || path[0] != '/' || strcmp(path, exe) == 0)
            continue;
        if (strcmp(path, last) == 0) /* one file's mappings are adjacent */
            continue;
        snprintf(last, sizeof last, "%s", path);
        check_loaded(path);
    }
    fclose(maps);
#else
#error "vips-loader-probe supports macOS and Linux"
#endif
    if (loaded_from_stage == 0) {
        printf("FAIL: nothing was loaded from %s at all\n", stage_real);
        failures++;
    }
    printf("      %d images in the process, %d from the bundle, the rest system\n",
        loaded_count, loaded_from_stage);
}

int
main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <libvips> <stage-dir> <work-dir>\n", argv[0]);
        return 2;
    }
    const char *libvips = argv[1], *work = argv[3];
    if (!realpath(argv[2], stage_real)) {
        printf("FAIL: no stage directory %s\n", argv[2]);
        return 2;
    }
    stage_len = strlen(stage_real);

    void *lib = dlopen(libvips, RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        printf("FAIL: dlopen %s: %s\n", libvips, dlerror());
        return 1;
    }
    p_vips_init = need(lib, "vips_init");
    p_vips_version_string = need(lib, "vips_version_string");
    p_vips_type_find = need(lib, "vips_type_find");
    p_vips_error_buffer = need(lib, "vips_error_buffer");
    p_vips_error_clear = need(lib, "vips_error_clear");
    p_vips_black = need(lib, "vips_black");
    p_vips_image_write_to_file = need(lib, "vips_image_write_to_file");
    p_vips_tiffsave = need(lib, "vips_tiffsave");
    p_vips_call = need(lib, "vips_call");
    p_vips_avg = need(lib, "vips_avg");
    p_vips_image_get_width = need(lib, "vips_image_get_width");
    p_vips_image_get_height = need(lib, "vips_image_get_height");
    p_g_object_unref = need(lib, "g_object_unref");

    if (p_vips_init("vips-loader-probe") != 0) {
        fail("vips_init");
        return 1;
    }
    printf("libvips %s from %s\n", p_vips_version_string(), libvips);

    /* 1. registration */
    static const char *loaders[] = {
        "pngload", "jpegload", "webpload", "tiffload", "gifload", "svgload",
        "heifload", "jxlload", "openslideload", "pdfload",
        NULL
    };
    for (int i = 0; loaders[i]; i++) {
        if (p_vips_type_find("VipsOperation", loaders[i]) == 0) {
            printf("FAIL: no %s operation registered\n", loaders[i]);
            failures++;
        }
        else
            printf("ok:   %s registered\n", loaders[i]);
    }
    static const char *absent[] = { "magickload", "magicksave", NULL };
    for (int i = 0; absent[i]; i++) {
        if (p_vips_type_find("VipsOperation", absent[i]) != 0) {
            printf("FAIL: %s is registered: the ImageMagick module is in the bundle\n",
                absent[i]);
            failures++;
        }
        else
            printf("ok:   no %s (no ImageMagick)\n", absent[i]);
    }

    /* 2. decode a real file through each loader */
    VipsImage *img = NULL;
    if (p_vips_black(&img, 256, 192, "bands", 3, NULL) != 0 || !img) {
        fail("vips_black");
        return 1;
    }
    round_trip(img, work, "probe.png", NULL, NULL, "pngload");
    round_trip(img, work, "probe.jpg", NULL, NULL, "jpegload");
    round_trip(img, work, "probe.webp", NULL, NULL, "webpload");
    round_trip(img, work, "probe.tif", NULL, NULL, "tiffload");
    round_trip(img, work, "probe.avif", NULL, NULL, "heifload");
    round_trip(img, work, "probe.heic", NULL, NULL, "heifload");
    round_trip(img, work, "probe.jxl", NULL, NULL, "jxlload");

    char path[PATH_MAX];
    path_join(path, sizeof path, work, "probe.gif");
    if (write_gif(path, 16, 12) != 0) {
        printf("FAIL: could not write %s\n", path);
        failures++;
    }
    else
        load_by_name("gifload", path, 16, 12);

    /* OpenSlide reads a tiled TIFF as its "generic-tiff" vendor. */
    path_join(path, sizeof path, work, "probe-tiled.tif");
    if (p_vips_tiffsave(img, path, "tile", 1, "pyramid", 1, NULL) != 0)
        fail("could not write the tiled TIFF fixture for openslideload");
    else
        load_by_name("openslideload", path, 256, 192);
    p_g_object_unref(img);

    path_join(path, sizeof path, work, "probe.pdf");
    if (write_pdf(path) != 0) {
        printf("FAIL: could not write %s\n", path);
        failures++;
    }
    else
        load_by_name("pdfload", path, 72, 72);

    path_join(path, sizeof path, work, "probe.svg");
    if (write_svg(path) != 0) {
        printf("FAIL: could not write %s\n", path);
        failures++;
    }
    else
        load_by_name("svgload", path, 40, 30);

    /* 3. self-containment, after every module and codec has loaded */
    check_process_images();

    if (failures) {
        printf("%d check(s) FAILED\n", failures);
        return 1;
    }
    printf("all checks passed\n");
    return 0;
}
