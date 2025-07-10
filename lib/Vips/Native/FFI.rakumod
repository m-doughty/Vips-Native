unit module Vips::Native::FFI;

use NativeCall;
use MacOS::NativeLib <vips gobject-2.0>;

# VipsInteresting
constant VIPS_INTERESTING_NONE      is export = 0;
constant VIPS_INTERESTING_CENTRE    is export = 1;
constant VIPS_INTERESTING_ENTROPY   is export = 2;
constant VIPS_INTERESTING_ATTENTION is export = 3;
constant VIPS_INTERESTING_LOW       is export = 4;
constant VIPS_INTERESTING_HIGH      is export = 5;
constant VIPS_INTERESTING_ALL       is export = 6;

# VipsKernel
constant VIPS_KERNEL_NEAREST    is export = 0;
constant VIPS_KERNEL_LINEAR     is export = 1;
constant VIPS_KERNEL_CUBIC      is export = 2;
constant VIPS_KERNEL_MITCHELL   is export = 3;
constant VIPS_KERNEL_LANCZOS2   is export = 4;
constant VIPS_KERNEL_LANCZOS3   is export = 5;
constant VIPS_KERNEL_MKS2013    is export = 6;
constant VIPS_KERNEL_MKS2021    is export = 7;

# VIPS booleans (for gboolean)
constant VIPS_FALSE is export = 0;
constant VIPS_TRUE  is export = 1;

# vips_init
sub vips_init(Str --> int32) is native('vips') is export { * }

# VipsImage* is just an OpaquePointer
class VipsImage is repr('CPointer') is export { }

# vips_image_new_from_file(const char* name, ...)
sub vips_image_new_from_file(Str, Str --> VipsImage) is native('vips') is export { * }

# Get dimensions
sub vips_image_get_width(VipsImage --> int32) is native('vips') is export { * }
sub vips_image_get_height(VipsImage --> int32) is native('vips') is export { * }

# Smartcrop
sub vips_smartcrop(
	VipsImage,              # in
	CArray[VipsImage],      # out (pointer to VipsImage*)
	int32,                     # width
	int32,                     # height
	Str,                       # "interesting"
	int32,                     # VIPS_INTERESTING_*
	Str                        # NULL terminator for varargs
) returns int32 is native('vips') is export { * }

# Resize
sub vips_resize(
	VipsImage,                 # in
	CArray[VipsImage],         # out (pointer to VipsImage*)
	num64,                     # scale
	Str,                       # "kernel"
	int32,                     # VIPS_KERNEL_*
	Str                        # NULL terminator for varargs
) returns int32 is native('vips') is export { * }

# Save PNG
sub vips_pngsave(
	VipsImage,                  # in
	Str,                        # filename
	Str                         # NULL terminator for varargs
) returns int32 is native('vips') is export { * }

# Memory cleanup for images (from GLib/GObject)
sub g_object_unref(VipsImage) is native('gobject-2.0') is export { * }

