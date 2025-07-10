[![Actions Status](https://github.com/m-doughty/Vips-Native/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/Vips-Native/actions)

NAME
====

Vips::Native - Very light vips wrapper for making thumbnails

SYNOPSIS
========

```raku
use Vips::Native;

smart-resize("t/fixtures/camelia.png", "t/fixtures/out2.png", 128, 128);
```

STATUS
------

This module is a very minimal FFI wrapper for libvips for smart image resizing (my use case was making thumbnails). I may add more functionality later.

Pull requests are welcome if you want to add more vips functionality.

You will need vips installed, I refuse to vendor glib.

On MacOS: brew install vips

On Ubuntu: sudo apt install libvips-dev

I don't know why the GitHub Actions are failing on MacOS. The library runs on MacOS, that's where I built it.

EXTERNAL API
============

Vips::Native
------------

### smart-resize(Str $in-path, Str $out-path, Int $out-width, Int $out-height --> Bool)

Takes the input at $in-path, crops it to the right aspect ratio based on attention filter, then resizes to $out-width x $out-height and saves it to $out-path as a PNG.

vips_smart_resize --in=/path/to/image.png --out=/path/to/save.png --width=180 --height=180
------------------------------------------------------------------------------------------

Also installs a script to resize images as per above.

AUTHOR
======

  * Matt Doughty

COPYRIGHT AND LICENSE
=====================

Copyright 2025 Matt Doughty

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

