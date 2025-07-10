unit module Vips::Native;

use Vips::Native::FFI;
use NativeCall;

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
