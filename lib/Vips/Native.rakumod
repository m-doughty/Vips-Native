unit module Vips::Native;

use Vips::Native::FFI;
use NativeCall;

# --- init discipline ------------------------------------------------------
#
# vips_init is NOT safe to run lazily on a worker thread. Since the
# bundle grew vips-modules (r11: heif/jxl/magick/openslide/poppler),
# vips_init runs vips_load_plugins, which dlopens each module — and a
# dlopen storm on a worker thread can deadlock against ANY other
# thread's dlopen (observed 2026-08-11 in a consumer app, sampled live:
# worker holds dyld's API lock inside vips_init → g_module_open →
# dlopen → plugin initializers → libintl rwlock, while the main
# thread's own unrelated dlopen waits on dyld's lock and every other
# thread parks at MoarVM's GC barrier — total process freeze, no
# error). The fix is to make init deterministic: exactly once, at
# module load time, on the loading thread, before consumers spawn
# workers or trigger competing lazy NativeCall setups.
#
# All public entry points call ensure-vips-init (idempotent,
# lock-guarded) rather than vips_init directly, so a consumer that
# somehow defeats INIT ordering still cannot double-init or race two
# inits; the INIT phaser makes the normal path run at load time.
# vips honours VIPS_NOVIPS in the environment to skip plugin loading
# entirely — an escape hatch if a bundled module ever misbehaves.

# INIT phasers in a precompiled unit fire BEFORE the module mainline,
# so the lock cannot be built by a mainline initializer — the INIT
# block below constructs it (single-threaded at that point) and the
# defensive //= covers only the never-in-practice case of a caller
# racing in before INIT has run.
my Lock $vips-init-lock;
my Bool $vips-initialised = False;

#|( Initialise libvips exactly once, thread-safely. Runs at module
    load via INIT; safe (and free) to call again from any entry
    point. The C<$progname> only labels vips's error contexts, so
    whichever caller gets there first wins it. )
sub ensure-vips-init(Str $progname = 'raku-vips') is export {
    ($vips-init-lock //= Lock.new).protect: {
        unless $vips-initialised {
            vips_init($progname);
            $vips-initialised = True;
        }
    }
}

INIT {
    $vips-init-lock //= Lock.new;
    ensure-vips-init();
}

#|( Smart-crop + resize an image to fixed output dimensions, saving
    the result as a PNG. Uses libvips's "interesting"-driven
    smartcrop (saliency / entropy / attention) to pick the most
    important rectangle, then Lanczos3-resizes that to the requested
    output size.

    Returns True on success; fails with an error message on bad
    input. The caller doesn't see VipsImage objects directly — this
    is the convenience entry point. )
sub smart-resize(
	Str $in-path,
	Str $out-path,
	Int $out-width,
	Int $out-height --> Bool
) is export {
	ensure-vips-init("vips-smart-resize");
	fail "No file found at $in-path" unless $in-path.IO.e && $in-path.IO.r;

	# Load input
	my VipsImage $input = vips_image_new_from_file($in-path, Str);
	fail "Does not appear to be an image file: $in-path" unless $input.defined;

	# Input dimensions
	my $in-width  = vips_image_get_width($input);
	my $in-height = vips_image_get_height($input);
	my $in-ratio  = $in-width / $in-height;
	my $out-ratio = $out-width / $out-height;

	# Determine crop target
	my ($crop-width, $crop-height) = $in-ratio > $out-ratio
		?? ($in-height * $out-ratio, $in-height)
		!! ($in-width, $in-width / $out-ratio);

	$crop-width  = $crop-width.Int;
	$crop-height = $crop-height.Int;

	# Smartcrop
	my $cropped = CArray[VipsImage].new;
	$cropped[0] = VipsImage;
	my $ok = vips_smartcrop($input, $cropped, $crop-width, $crop-height,
		"interesting", VIPS_INTERESTING_ATTENTION, Str);
	fail "Failed to crop image" if $ok != 0;

	# Resize
	my $resized = CArray[VipsImage].new;
	$resized[0] = VipsImage;
	$ok = vips_resize(
		$cropped[0],
		$resized,
		($out-width / $crop-width).Num,
		"kernel", VIPS_KERNEL_LANCZOS3, Str
	);
	fail "Failed to resize image" if $ok != 0;

	# Save
	$ok = vips_pngsave($resized[0], $out-path, Str);
	fail "Failed to save image to $out-path" if $ok != 0;

	# Cleanup memory
	g_object_unref($_) for $input, $cropped[0], $resized[0];

	return True;
}

#|( Letterbox-resize an image to a fixed square and return the raw
    8-bit RGB pixel buffer. Aspect ratio is preserved — the source
    is shrunk to fit inside C<$size × $size>, then the gap is
    padded with C<@bg> (default white). RGBA inputs have their
    alpha composited onto C<@bg> first, so the returned buffer is
    always C<$size × $size × 3> bytes — no alpha channel survives.

    This is the preprocess pipeline ML image classifiers want: fixed
    input dimensions, deterministic colour fill in the unfilled
    region, NHWC byte order. The returned buffer is suitable to
    feed to ONNX-Native via C<Tensor.from-blob> after band-reorder
    (to BGR) and float cast.

    =begin code :lang<raku>
    use Vips::Native;

    my $bytes = letterbox-to-buffer('photo.png', :size(448));
    say $bytes.bytes;        # 448 * 448 * 3 = 602112
    =end code

    Bands handling: input must be 1, 3, or 4 bands (greyscale, RGB,
    or RGBA); other formats are rejected because the BGR conversion
    in callers wouldn't be well-defined. Greyscale is broadcast to
    R=G=B by libvips's flatten path. Format must be UCHAR (8-bit
    per channel) — 16-bit / float images aren't supported in v1.

    Failures:
    =item No such file → C<fail>s with the path.
    =item Unsupported format / band count → C<fail>s with details.
    =item libvips error → C<fail>s with libvips's most recent error.

    The buffer returned is owned by the caller's GC — internally
    we copy out of vips_image_write_to_memory's g_malloc'd buffer
    and release the source via vips_shim_free, so there's no
    GC-vs-libvips ownership trap.

    Platforms: macOS arm64, Linux x86_64 + aarch64 (glibc), and
    Windows x86_64 + arm64 are supported. The shim ships in every
    prebuilt bundle.
    )
sub letterbox-to-buffer(
    IO::Path() $path,
    UInt :$size = 448,
    :@bg = (255, 255, 255),
    --> Buf[uint8]
) is export {
    fail "No file found at $path" unless $path.e && $path.r;
    fail "Background must be 3 RGB doubles, got @bg.elems()"
        unless @bg.elems == 3;

    ensure-vips-init("vips-letterbox");

    my VipsImage $loaded = vips_image_new_from_file($path.Str, Str);
    fail "Could not load image: $path" unless $loaded.defined;
    LEAVE { g_object_unref($loaded) with $loaded }

    # 1. Flatten alpha onto $bg, but only if the source actually has
    # an alpha channel. libvips's flatten errors (rc=-1) on 3-band
    # RGB inputs rather than treating it as a no-op, so we probe the
    # band count first. 4-band → RGBA → flatten to 3-band RGB.
    # 3-band RGB → use directly. Other counts (greyscale, CMYK,
    # multi-spectral) are out of scope for v1 — fail with details
    # rather than silently mis-encoding.
    my $loaded-bands = vips_image_get_bands($loaded);
    my VipsImage $rgb;
    my $flattened-handle;
    my Int $rc;
    if $loaded-bands == 4 {
        my $flattened = CArray[VipsImage].new;
        $flattened[0] = VipsImage;
        $rc = vips_flatten($loaded, $flattened,
            @bg[0].Num, @bg[1].Num, @bg[2].Num);
        fail "vips_flatten failed (rc=$rc)" if $rc != 0;
        $rgb = $flattened[0];
        $flattened-handle = $rgb;
    } elsif $loaded-bands == 3 {
        $rgb = $loaded;
    } else {
        fail "Unsupported band count $loaded-bands (expected 3 RGB or 4 RGBA)";
    }
    LEAVE { g_object_unref($flattened-handle) with $flattened-handle }

    # Reject non-UCHAR formats. Some HDR / EXR / 16-bit PNG sources
    # land here as USHORT or FLOAT; we can't safely write those as
    # 8-bit without an explicit cast step (out of scope for v1).
    my $format = vips_image_get_format($rgb);
    fail "Expected 8-bit UCHAR pixels, got format-id $format"
        unless $format == VIPS_FORMAT_UCHAR;

    # 2. Resize so the longer side fits within $size.
    my $w = vips_image_get_width($rgb);
    my $h = vips_image_get_height($rgb);
    my Num $scale = ($size / max($w, $h)).Num;

    my $resized = CArray[VipsImage].new;
    $resized[0] = VipsImage;
    $rc = vips_resize($rgb, $resized, $scale, "kernel", VIPS_KERNEL_LANCZOS3, Str);
    fail "vips_resize failed (rc=$rc)" if $rc != 0;
    my VipsImage $small = $resized[0];
    LEAVE { g_object_unref($small) with $small }

    my $small-w = vips_image_get_width($small);
    my $small-h = vips_image_get_height($small);

    # 3. Embed in $size × $size canvas with $bg fill, image centred.
    my Int $off-x = (($size - $small-w) / 2).floor;
    my Int $off-y = (($size - $small-h) / 2).floor;

    my $embedded = CArray[VipsImage].new;
    $embedded[0] = VipsImage;
    $rc = vips_embed($small, $embedded,
        $off-x, $off-y, $size.Int, $size.Int,
        VIPS_EXTEND_BACKGROUND,
        @bg[0].Num, @bg[1].Num, @bg[2].Num);
    fail "vips_embed failed (rc=$rc)" if $rc != 0;
    my VipsImage $canvas = $embedded[0];
    LEAVE { g_object_unref($canvas) with $canvas }

    # 4. Write raw bytes. vips_image_write_to_memory g_malloc's a
    # buffer of width*height*bands*sizeof(elem); for our UCHAR/3-band
    # canvas that's exactly size*size*3 bytes.
    my $size-out = CArray[uint64].new;
    $size-out[0] = 0;
    my $ptr = vips_image_write_to_memory($canvas, $size-out);
    fail "vips_image_write_to_memory returned NULL" without $ptr;

    my $expected = $size * $size * 3;
    my $got      = $size-out[0].Int;
    if $got != $expected {
        vips_shim_free($ptr);
        fail "vips_image_write_to_memory returned $got bytes, expected $expected";
    }

    # Copy out into a Raku-owned Buf so we can free the GLib buffer
    # immediately — no lifetime entanglement between the caller and
    # libvips/glib's heap. nativecast(CArray[uint8], $ptr) gives us
    # an indexable view; we walk it byte-by-byte into the Buf.
    my $bytes = nativecast(CArray[uint8], $ptr);
    my $out = buf8.allocate($expected);
    $out[$_] = $bytes[$_] for ^$expected;

    vips_shim_free($ptr);

    $out;
}

#|( A decoded, tightly-packed 4-band RGBA pixel buffer plus its pixel
    dimensions. C<rgba> is exactly C<width × height × 4> bytes in
    R, G, B, A byte order — the layout notcurses' C<ncvisual_from_rgba>
    consumes directly (rows = height, cols = width, rowstride = width × 4).

    Produced by C<decode-to-rgba>. Unlike a file path, nothing here ever
    touches disk: the bytes live only in this Buf, so an encrypted source
    blob can be rendered without spilling plaintext to a temp file. )
class RawRgba is export {
    has UInt     $.width;
    has UInt     $.height;
    has Buf[uint8] $.rgba;
}

# Shared tail of decode-to-rgba: normalise a loaded VipsImage to 8-bit
# sRGB, force a 4-band RGBA layout, and copy the raw pixels into a
# GC-owned Buf. The caller owns $loaded's lifetime — and, on the buffer
# path, must keep the encoded source buffer alive across this call,
# because libvips decodes lazily right down to vips_image_write_to_memory.
sub _rgba-from-vips(VipsImage $loaded --> RawRgba) {
    # 1. Normalise colourspace → 8-bit sRGB. One step handles greyscale,
    # CMYK, 16-bit, palette, etc.; an existing alpha band passes through.
    my $cs = CArray[VipsImage].new;
    $cs[0] = VipsImage;
    my Int $rc = vips_colourspace($loaded, $cs, VIPS_INTERPRETATION_sRGB);
    fail "vips_colourspace failed (rc=$rc)" if $rc != 0;
    my VipsImage $srgb = $cs[0];
    LEAVE { g_object_unref($srgb) with $srgb }

    # 2. Force 4-band RGBA. sRGB output is 3-band (opaque source) or
    # 4-band (alpha carried through); add an opaque alpha only when absent
    # — vips_addalpha raises if the image already has one.
    my VipsImage $rgba-img;
    my $added-handle;
    if vips_image_get_bands($srgb) < 4 {
        my $aa = CArray[VipsImage].new;
        $aa[0] = VipsImage;
        $rc = vips_addalpha($srgb, $aa);
        fail "vips_addalpha failed (rc=$rc)" if $rc != 0;
        $rgba-img      = $aa[0];
        $added-handle  = $rgba-img;
    } else {
        $rgba-img = $srgb;
    }
    LEAVE { g_object_unref($added-handle) with $added-handle }

    # 3. colourspace(sRGB) yields UCHAR; assert before trusting the byte
    # count so a surprise format fails loudly instead of mis-rendering.
    my $format = vips_image_get_format($rgba-img);
    fail "Expected 8-bit UCHAR pixels after sRGB convert, got format-id $format"
        unless $format == VIPS_FORMAT_UCHAR;

    my $w = vips_image_get_width($rgba-img);
    my $h = vips_image_get_height($rgba-img);

    # 4. Materialise. g_malloc'd buffer of exactly w*h*4 bytes (RGBA UCHAR).
    my $size-out = CArray[uint64].new;
    $size-out[0] = 0;
    my $ptr = vips_image_write_to_memory($rgba-img, $size-out);
    fail "vips_image_write_to_memory returned NULL" without $ptr;

    my $expected = $w * $h * 4;
    my $got      = $size-out[0].Int;
    if $got != $expected {
        vips_shim_free($ptr);
        fail "vips_image_write_to_memory returned $got bytes, "
            ~ "expected $expected (w=$w h=$h, 4-band RGBA)";
    }

    my $bytes = nativecast(CArray[uint8], $ptr);
    my $out   = buf8.allocate($expected);
    $out[$_] = $bytes[$_] for ^$expected;
    vips_shim_free($ptr);

    RawRgba.new(:width($w.UInt), :height($h.UInt), :rgba($out));
}

#|( Decode an encoded image to raw RGBA pixels in memory, preserving
    aspect ratio and any alpha channel. The complement of
    C<letterbox-to-buffer> (which squares the image and drops alpha for
    ML preprocessing) — this is for faithful display.

    Two forms: decode from an in-memory C<Blob> of encoded bytes (PNG /
    JPEG / WebP / …) or from a file C<IO::Path>. The Blob form is the
    privacy-preserving path: bytes pulled from an encrypted store decode
    straight to pixels with nothing written to disk.

    =begin code :lang<raku>
    use Vips::Native;

    # From an encrypted blob already in RAM:
    my $img = decode-to-rgba($png-bytes);
    say "{$img.width}×{$img.height}, {$img.rgba.bytes} bytes";  # w*h*4

    # From a file (e.g. a legacy on-disk avatar):
    my $img2 = decode-to-rgba('avatar.png'.IO);
    =end code

    Returns a L<RawRgba|#RawRgba>. The colourspace is normalised to 8-bit
    sRGB (greyscale, CMYK, 16-bit and palette sources are converted) and
    the result is always 4-band RGBA, so C<rgba.bytes == width*height*4>.

    Failures:
    =item Empty buffer / missing file → C<fail>s with details.
    =item Undecodable / corrupt bytes → C<fail>s.
    =item Non-UCHAR result after convert → C<fail>s rather than mis-render.

    Lifetime note (Blob form): C<vips_image_new_from_buffer> does not copy
    its input, so the encoded bytes are copied into a native buffer rooted
    for the duration of the decode. The returned C<RawRgba.rgba> is fully
    GC-owned with no tie to libvips's heap.

    Platforms: macOS arm64, Linux x86_64 + aarch64 (glibc), Windows
    x86_64 + arm64. The shim ships in every prebuilt bundle. )
multi decode-to-rgba(Blob:D $encoded --> RawRgba) is export {
    fail "Empty image buffer" unless $encoded.elems > 0;
    ensure-vips-init("vips-decode-rgba");

    # Copy the encoded bytes into a native CArray we control. libvips
    # references this buffer lazily (it is NOT copied by
    # vips_image_new_from_buffer) and reads it as late as
    # vips_image_write_to_memory inside _rgba-from-vips, so it must stay
    # alive across the whole pipeline. Root it via LEAVE — registered
    # FIRST so it runs LAST, after the $loaded unref below.
    my $enc-ca = CArray[uint8].allocate($encoded.elems);
    $enc-ca[$_] = $encoded[$_] for ^$encoded.elems;
    LEAVE { $enc-ca.so }

    my VipsImage $loaded =
        vips_image_new_from_buffer(nativecast(Pointer, $enc-ca), $encoded.elems);
    fail "Could not decode image buffer (unknown / corrupt format)"
        unless $loaded.defined;
    LEAVE { g_object_unref($loaded) with $loaded }

    _rgba-from-vips($loaded);
}

multi decode-to-rgba(IO::Path:D $path --> RawRgba) is export {
    fail "No file found at $path" unless $path.e && $path.r;
    ensure-vips-init("vips-decode-rgba");

    my VipsImage $loaded = vips_image_new_from_file($path.Str, Str);
    fail "Could not load image: $path" unless $loaded.defined;
    LEAVE { g_object_unref($loaded) with $loaded }

    _rgba-from-vips($loaded);
}

#|( Smart-crop + resize an encoded image held in memory to fixed output
    dimensions, returning the result PNG-encoded as a C<Buf>. The
    in-memory analogue of C<smart-resize>: same saliency-driven crop and
    Lanczos3 resize, but the source arrives as bytes and the result
    leaves as bytes, so no temp file ever touches disk.

    =begin code :lang<raku>
    use Vips::Native;

    my $thumb-png = smart-resize-buffer($full-png-bytes, 100, 100);
    # $thumb-png is a PNG-encoded Buf ready to store as an encrypted blob
    =end code

    Use this to generate thumbnails / avatars from encrypted source bytes
    without spilling either the source or the result to disk. Decode the
    returned PNG with C<decode-to-rgba> when it's time to display.

    Failures: empty input, non-positive dimensions, undecodable bytes, or
    any libvips error → C<fail>s with details. )
sub smart-resize-buffer(
    Blob:D $in, UInt $out-width, UInt $out-height --> Buf[uint8]
) is export {
    fail "Empty input buffer" unless $in.elems > 0;
    fail "Output dimensions must be positive"
        unless $out-width > 0 && $out-height > 0;
    ensure-vips-init("vips-smart-resize-buffer");

    # Same lazy-buffer lifetime contract as decode-to-rgba — root the
    # encoded CArray across the pipeline (pngsave_buffer forces the read).
    my $enc-ca = CArray[uint8].allocate($in.elems);
    $enc-ca[$_] = $in[$_] for ^$in.elems;
    LEAVE { $enc-ca.so }

    my VipsImage $input =
        vips_image_new_from_buffer(nativecast(Pointer, $enc-ca), $in.elems);
    fail "Could not decode image buffer (unknown / corrupt format)"
        unless $input.defined;
    LEAVE { g_object_unref($input) with $input }

    my $in-width  = vips_image_get_width($input);
    my $in-height = vips_image_get_height($input);
    my $in-ratio  = $in-width / $in-height;
    my $out-ratio = $out-width / $out-height;

    my ($crop-width, $crop-height) = $in-ratio > $out-ratio
        ?? ($in-height * $out-ratio, $in-height)
        !! ($in-width, $in-width / $out-ratio);
    $crop-width  = $crop-width.Int;
    $crop-height = $crop-height.Int;

    my $cropped = CArray[VipsImage].new;
    $cropped[0] = VipsImage;
    my Int $rc = vips_smartcrop($input, $cropped, $crop-width, $crop-height,
        "interesting", VIPS_INTERESTING_ATTENTION, Str);
    fail "vips_smartcrop failed (rc=$rc)" if $rc != 0;
    my VipsImage $crop = $cropped[0];
    LEAVE { g_object_unref($crop) with $crop }

    my $resized = CArray[VipsImage].new;
    $resized[0] = VipsImage;
    $rc = vips_resize($crop, $resized,
        ($out-width / $crop-width).Num,
        "kernel", VIPS_KERNEL_LANCZOS3, Str);
    fail "vips_resize failed (rc=$rc)" if $rc != 0;
    my VipsImage $small = $resized[0];
    LEAVE { g_object_unref($small) with $small }

    # Encode to PNG in memory. $buf-out[0] becomes a g_malloc'd Pointer.
    my $buf-out = CArray[Pointer].new;
    $buf-out[0] = Pointer;
    my $len-out = CArray[uint64].new;
    $len-out[0] = 0;
    $rc = vips_pngsave_buffer($small, $buf-out, $len-out);
    fail "vips_pngsave_buffer failed (rc=$rc)" if $rc != 0;
    my $ptr = $buf-out[0];
    fail "vips_pngsave_buffer returned NULL" without $ptr;

    my $n     = $len-out[0].Int;
    my $bytes = nativecast(CArray[uint8], $ptr);
    my $out   = buf8.allocate($n);
    $out[$_] = $bytes[$_] for ^$n;
    vips_shim_free($ptr);

    $out;
}
