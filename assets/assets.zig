//! Some assets are embedded while others are loaded dynamically.
//! This file is for embedded assets.

pub const fonts = struct {
    pub const dejavu_sans = @embedFile("embedded/DejaVuSans.ttf");
};
