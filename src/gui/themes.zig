const dvui = @import("dvui");
const Color = dvui.Color;
const Font = dvui.Font;
const Theme = dvui.Theme;
const Options = dvui.Options;

pub const Papyrus = struct {
    pub const cursor: Color = .fromHex("#982500");
    pub const bg_main: Color = .fromHex("#e0d8c7");
    pub const fg_main: Color = .fromHex("#202020");
    pub const border: Color = .fromHex("#8f9373");
    pub const bg_shadow_subtle: Color = .fromHex("#d5c9b5");
    pub const fg_shadow_subtle: Color = .fromHex("#595959");
    pub const bg_neutral: Color = .fromHex("#c2b19e");
    pub const fg_neutral: Color = .fromHex("#4a4a4a");
    pub const bg_shadow_intense: Color = .fromHex("#b0b0b0");
    pub const fg_shadow_intense: Color = .fromHex("#404040");
    pub const bg_accent: Color = .fromHex("#e3b8a0");
    pub const fg_accent: Color = .fromHex("#603d3a");
    pub const fg_red: Color = .fromHex("#982500");
    pub const fg_green: Color = .fromHex("#226700");
    pub const fg_yellow: Color = .fromHex("#595000");
    pub const fg_blue: Color = .fromHex("#103077");
    pub const fg_magenta: Color = .fromHex("#700054");
    pub const fg_cyan: Color = .fromHex("#005460");
    pub const bg_red: Color = .fromHex("#e3b8a0");
    pub const bg_green: Color = .fromHex("#b8caa0");
    pub const bg_yellow: Color = .fromHex("#dfc085");
    pub const bg_blue: Color = .fromHex("#c4c8dd");
    pub const bg_magenta: Color = .fromHex("#d8bade");
    pub const bg_cyan: Color = .fromHex("#bee0db");

    const adwaita_light = Theme.builtin.adwaita_light;

    pub const light = light: {
        @setEvalBranchQuota(3123);
        break :light Theme{
            .name = "Papyrus",
            .dark = false,

            // .embedded_fonts = fonts,

            .font_body = .find(.{ .family = "Vera Sans" }),
            .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
            .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
            .font_mono = .find(.{ .family = "Vera Sans Mono" }),

            .focus = bg_neutral,

            .fill = bg_main,
            .fill_hover = (Color.HSLuv{ .s = 0, .l = 82 }).color(),
            .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
            .text = Color.black,
            .text_select = .{ .r = 0x91, .g = 0xbc, .b = 0xf0 },
            .border = (Color.HSLuv{ .s = 0, .l = 63 }).color(),

            .control = .{
                .fill = bg_shadow_subtle,
                .fill_hover = bg_neutral,
                .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
            },

            .window = .{
                .fill = bg_main,
            },

            .highlight = .{
                .fill = bg_neutral,
                .fill_hover = adwaita_light.highlight.fill_hover,
                .fill_press = adwaita_light.highlight.fill_press,
                .text = Color.white,
                .border = adwaita_light.highlight.border,
            },

            .err = .{
                .fill = adwaita_light.err.fill,
                .fill_hover = adwaita_light.err.fill_hover,
                .fill_press = adwaita_light.err.fill_press,
                .text = Color.white,
                .border = adwaita_light.err.border,
            },
        };
    };
};


pub const Obsidian = struct {
    pub const cursor: Color = .fromHex("#eeddbb");
    pub const bg_main: Color = .fromHex("#181818");
    pub const fg_main: Color = .fromHex("#e7e7e7");
    pub const border: Color = .fromHex("#727272");
    pub const bg_shadow_subtle: Color = .fromHex("#2f2f2f");
    pub const fg_shadow_subtle: Color = .fromHex("#969696");
    pub const bg_neutral: Color = .fromHex("#3a3a3a");
    pub const fg_neutral: Color = .fromHex("#bcbcbc");
    pub const bg_shadow_intense: Color = .fromHex("#505050");
    pub const fg_shadow_intense: Color = .fromHex("#b0b0b0");
    pub const bg_accent: Color = .fromHex("#432f2a");
    pub const fg_accent: Color = .fromHex("#b59487");
    pub const fg_red: Color = .fromHex("#eca28f");
    pub const fg_green: Color = .fromHex("#b9d0aa");
    pub const fg_yellow: Color = .fromHex("#c0b080");
    pub const fg_blue: Color = .fromHex("#9fbfe7");
    pub const fg_magenta: Color = .fromHex("#e9acbf");
    pub const fg_cyan: Color = .fromHex("#a0c0d0");
    pub const bg_red: Color = .fromHex("#4d1f20");
    pub const bg_green: Color = .fromHex("#1f402e");
    pub const bg_yellow: Color = .fromHex("#504432");
    pub const bg_blue: Color = .fromHex("#223567");
    pub const bg_magenta: Color = .fromHex("#603254");
    pub const bg_cyan: Color = .fromHex("#2f4f54");

    const adwaita_dark = Theme.builtin.adwaita_dark;

    pub const dark = dark: {
        @setEvalBranchQuota(3123);
        break :dark Theme{
            .name = "Obsidian",
            .dark = true,

            // .embedded_fonts = fonts,

            .font_body = .find(.{ .family = "Vera Sans" }),
            .font_heading = .find(.{ .family = "Vera Sans", .weight = .bold }),
            .font_title = .find(.{ .family = "Vera Sans", .size = dvui.Font.DefaultSize + 2 }),
            .font_mono = .find(.{ .family = "Vera Sans Mono" }),

            .focus = bg_neutral,

            .fill = bg_main,
            .fill_hover = (Color.HSLuv{ .s = 0, .l = 82 }).color(),
            .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
            .text = fg_main,
            .text_select = .{ .r = 0x91, .g = 0xbc, .b = 0xf0 },
            .border = (Color.HSLuv{ .s = 0, .l = 63 }).color(),

            .control = .{
                .fill = bg_shadow_subtle,
                .fill_hover = bg_neutral,
                .fill_press = (Color.HSLuv{ .s = 0, .l = 72 }).color(),
            },

            .window = .{
                .fill = bg_main,
            },

            .highlight = .{
                .fill = bg_neutral,
                .fill_hover = adwaita_dark.highlight.fill_hover,
                .fill_press = adwaita_dark.highlight.fill_press,
                .text = Color.white,
                .border = adwaita_dark.highlight.border,
            },

            .err = .{
                .fill = adwaita_dark.err.fill,
                .fill_hover = adwaita_dark.err.fill_hover,
                .fill_press = adwaita_dark.err.fill_press,
                .text = Color.white,
                .border = adwaita_dark.err.border,
            },
        };
    };
};
