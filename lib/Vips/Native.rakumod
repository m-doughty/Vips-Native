unit module Vips::Native;

use Vips::Native::FFI;
use NativeCall;

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
	vips_init("vips-smart-resize");
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
    Windows x86_64 are supported. Windows arm64 doesn't run Raku
    yet; the prebuilt for that platform omits the shim, so
    C<letterbox-to-buffer> dies with a "requires libvips_shim"
    message there until Raku ships an arm64 Windows build.
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

    vips_init("vips-letterbox");

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
